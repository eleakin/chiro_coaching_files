# pull_nv_board.R ------------------------------------------------------------
# Scrape the Chiropractic Physicians' Board of Nevada public licensee register
# (Thentia Cloud portal) into a CSV compatible with nv-chiropractor-list.csv.
#
# Run on your own machine:        Rscript pull_nv_board.R
# If the default endpoint fails:  Rscript pull_nv_board.R --probe
# One-time setup:                 install.packages(c("httr", "jsonlite"))
#
# Why this works: the register page at
#   https://nvcpbn.portalus.thentiacloud.net/webs/portal/register/#/
# is a JavaScript app. The data it displays comes from a public JSON API on the
# same host (the standard Thentia pattern used by licensing boards nationwide):
#   /rest/public/profile/search/?keyword=all&skip=0&take=20&lang=en
# This script pages through that API and flattens the results.
#
# This is public record data — NRS 634 requires the Board's roster to be open
# to public inspection. Be polite anyway: the script rate-limits between pages.
#
# Output:
#   nv-board-licensees.csv  one row per licensee, template-compatible columns
#   nv-board-raw.json       raw API records, so nothing is lost if the Board's
#                           field names don't match the mapping below

library(httr)
library(jsonlite)

BASE      <- "https://nvcpbn.portalus.thentiacloud.net"
SEARCH    <- paste0(BASE, "/rest/public/profile/search/")
PAGE_SIZE <- 100

HEADERS <- add_headers(
  # a normal browser UA — some WAFs reject default clients
  `User-Agent` = paste0("Mozilla/5.0 (Windows NT 10.0; Win64; x64) ",
                        "AppleWebKit/537.36 (KHTML, like Gecko) ",
                        "Chrome/126.0 Safari/537.36"),
  Accept    = "application/json",
  Referer   = paste0(BASE, "/webs/portal/register/")
)

# Thentia field names vary slightly per board; every observed variant listed.
# The REGISTER_PROFILE_LABEL_* names are Nevada's columnLayout labels, applied
# when the API returns positional rows (see extract_batch).
FIELD_MAP <- list(
  last    = c("REGISTER_PROFILE_LABEL_LAST_NAME", "lastName", "last_name",
              "surname"),
  first   = c("REGISTER_PROFILE_LABEL_FIRST_NAME", "firstName", "first_name",
              "givenName"),
  license = c("REGISTER_PROFILE_LABEL_LICENSE_NUMBER", "licenseNumber",
              "license_number", "registrationNumber", "licenceNumber"),
  status  = c("REGISTER_PROFILE_LABEL_LICENSE_STATUS", "status",
              "licenseStatus", "registrationStatus"),
  type    = c("REGISTER_PROFILE_LABEL_LICENSE_TYPE", "licenseType",
              "license_type", "registrationType", "profession"),
  city    = c("REGISTER_PROFILE_LABEL_CITY", "city", "addressCity",
              "practiceCity"),
  state   = c("state", "province", "addressState"),
  expiry  = c("REGISTER_PROFILE_LABEL_LICENSE_EXPIRY_DATE", "expiryDate",
              "expirationDate", "expiry"),
  id      = c("id", "profileId", "entityId")
)

pick <- function(rec, keys) {
  for (k in keys) {
    v <- rec[[k]]
    if (!is.null(v) && length(v) > 0 && nzchar(as.character(v)[1]))
      return(trimws(as.character(v)[1]))
  }
  ""
}

get_json <- function(url) {
  resp <- GET(url, HEADERS, timeout(30))
  stop_for_status(resp)
  fromJSON(content(resp, as = "text", encoding = "UTF-8"),
           simplifyVector = FALSE)
}

# Thentia responses come in three shapes: a bare list of records,
# {result: [...]}, or (Nevada's) {result: {dataResults: [...],
# columnLayout: [...]}} where each row is a positional array aligned to
# columnLayout. Normalize all three to a list of keyed records.
extract_batch <- function(data) {
  if (is.null(names(data))) return(data)              # bare list of records
  res <- data$result
  if (!is.null(res) && !is.null(names(res)) && !is.null(res$dataResults)) {
    layout <- unlist(res$columnLayout)
    return(lapply(res$dataResults, function(row) {
      if (!is.null(names(row))) return(row)           # already keyed
      row <- lapply(row, function(v) if (is.null(v)) "" else v)
      if (!is.null(layout) && length(row) == length(layout))
        return(setNames(row, layout))
      row
    }))
  }
  for (k in c("result", "results", "data")) {
    if (!is.null(data[[k]])) return(data[[k]])
  }
  list()
}

fetch_keyword <- function(keyword) {
  out <- list()
  skip <- 0
  repeat {
    url <- sprintf("%s?keyword=%s&skip=%d&take=%d&lang=en",
                   SEARCH, keyword, skip, PAGE_SIZE)
    data <- get_json(url)
    batch <- extract_batch(data)
    if (length(batch) == 0) break
    out <- c(out, batch)
    total <- if (is.null(names(data))) NULL else data$resultCount
    skip <- skip + PAGE_SIZE
    if (!is.null(total) && length(out) >= as.integer(total)) break
    if (skip > 5000) break  # safety cap — NV has ~645 DCs
    Sys.sleep(0.5)          # be polite to a state board server
  }
  out
}

# dedupe key for a raw record: license number, else id, else full name
rec_key <- function(rec) {
  k <- pick(rec, FIELD_MAP$license)
  if (!nzchar(k)) k <- pick(rec, FIELD_MAP$id)
  if (!nzchar(k)) k <- paste(pick(rec, FIELD_MAP$last),
                             pick(rec, FIELD_MAP$first))
  toupper(k)
}

fetch_all <- function() {
  # Some Thentia tenants return everything for keyword=all; others (including
  # Nevada's) return an empty set for it. Try "all" first, then fall back to
  # sweeping a-z — every name contains at least one letter — and dedupe.
  out <- fetch_keyword("all")
  if (length(out) > 0) {
    message("  fetched ", length(out), " via keyword=all")
    return(out)
  }
  message("  keyword=all returned nothing; sweeping a-z instead")
  seen <- character(0)
  for (letter in letters) {
    batch <- fetch_keyword(letter)
    fresh <- 0
    for (rec in batch) {
      k <- rec_key(rec)
      if (!(k %in% seen)) {
        seen <- c(seen, k)
        out <- c(out, list(rec))
        fresh <- fresh + 1
      }
    }
    message("  keyword=", letter, ": ", length(batch),
            " records (", fresh, " new, total ", length(out), ")")
    Sys.sleep(0.5)
  }
  out
}

probe <- function() {
  url <- sprintf("%s?keyword=all&skip=0&take=2&lang=en", SEARCH)
  message("Probing ", url, "\n")
  data <- tryCatch(get_json(url), error = function(e) e)
  if (inherits(data, "error")) {
    message("Endpoint failed: ", conditionMessage(data), "\n\n",
      "Find the real endpoint in 30 seconds:\n",
      "  1. Open the register page in Chrome:\n",
      "     ", BASE, "/webs/portal/register/#/\n",
      "  2. Press F12 -> Network tab -> filter 'Fetch/XHR'\n",
      "  3. Click Search on the page (leave the box empty or type 'all')\n",
      "  4. The request that returns licensee JSON is your endpoint —\n",
      "     copy its URL into SEARCH at the top of this script.\n")
    return(invisible(NULL))
  }
  batch <- extract_batch(data)
  if (length(batch) == 0) {
    message("Endpoint is LIVE but keyword=all returns nothing on this tenant.")
    message("Trying keyword=s to sample a real record...\n")
    data <- tryCatch(
      get_json(sprintf("%s?keyword=s&skip=0&take=2&lang=en", SEARCH)),
      error = function(e) e)
    if (inherits(data, "error")) {
      message("Sample query failed too: ", conditionMessage(data))
      return(invisible(NULL))
    }
    batch <- extract_batch(data)
    if (length(batch) == 0) {
      message("Still empty — the search likely needs different parameters.\n",
        "Open ", BASE, "/webs/portal/register/#/ in Chrome, press F12 ->\n",
        "Network -> Fetch/XHR, run a search on the page, and copy the URL\n",
        "of the request that returns licensee JSON into SEARCH above.")
      return(invisible(NULL))
    }
    message("Sample worked — main() will sweep a-z automatically.")
  } else {
    message("Endpoint is LIVE. First record keys:")
  }
  cat(substr(toJSON(batch[[1]], auto_unbox = TRUE, pretty = TRUE), 1, 1500),
      "\n")
}

main <- function() {
  if ("--probe" %in% commandArgs(trailingOnly = TRUE)) {
    probe()
    return(invisible(NULL))
  }
  message("Pulling NV Board licensee register...")
  records <- fetch_all()
  message("Total records: ", length(records))
  if (length(records) == 0) {
    message("No records returned — run with --probe to diagnose.")
    return(invisible(NULL))
  }

  write(toJSON(records, auto_unbox = TRUE, pretty = TRUE), "nv-board-raw.json")

  rows <- lapply(records, function(rec) {
    ltype <- pick(rec, FIELD_MAP$type)
    # keep DCs; skip chiropractic assistants unless you want them too
    if (nzchar(ltype) && grepl("assist", ltype, ignore.case = TRUE))
      return(NULL)
    data.frame(
      DC_LastName      = pick(rec, FIELD_MAP$last),
      DC_FirstName     = pick(rec, FIELD_MAP$first),
      License_Number   = pick(rec, FIELD_MAP$license),
      License_Status   = pick(rec, FIELD_MAP$status),
      License_Type     = ltype,
      City             = pick(rec, FIELD_MAP$city),
      State            = pick(rec, FIELD_MAP$state),
      License_Expiry   = pick(rec, FIELD_MAP$expiry),
      Board_Profile_Id = pick(rec, FIELD_MAP$id),
      Source           = "NV Board (Thentia)",
      stringsAsFactors = FALSE
    )
  })
  rows <- Filter(Negate(is.null), rows)
  df <- do.call(rbind, rows)

  write.csv(df, "nv-board-licensees.csv", row.names = FALSE, na = "")
  message("Wrote nv-board-licensees.csv (", nrow(df),
          " DCs) and nv-board-raw.json")
  message("\nNext: Rscript merge_lists.R  — folds license status into ",
          "nv-chiropractor-list.csv")
}

main()
