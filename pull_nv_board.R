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
# --probe prints the actual keys so you can extend these if needed.
FIELD_MAP <- list(
  last    = c("lastName", "last_name", "surname"),
  first   = c("firstName", "first_name", "givenName"),
  license = c("licenseNumber", "license_number", "registrationNumber",
              "licenceNumber"),
  status  = c("status", "licenseStatus", "registrationStatus"),
  type    = c("licenseType", "license_type", "registrationType", "profession"),
  city    = c("city", "addressCity", "practiceCity"),
  state   = c("state", "province", "addressState"),
  expiry  = c("expiryDate", "expirationDate", "expiry"),
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

# Thentia responses are either a bare list or {result: [...], resultCount: N}
extract_batch <- function(data) {
  if (is.null(names(data))) return(data)              # bare list of records
  for (k in c("result", "results", "data")) {
    if (!is.null(data[[k]])) return(data[[k]])
  }
  list()
}

fetch_all <- function() {
  out <- list()
  skip <- 0
  repeat {
    url <- sprintf("%s?keyword=all&skip=%d&take=%d&lang=en",
                   SEARCH, skip, PAGE_SIZE)
    data <- get_json(url)
    batch <- extract_batch(data)
    if (length(batch) == 0) break
    out <- c(out, batch)
    total <- if (is.null(names(data))) NULL else data$resultCount
    skip <- skip + PAGE_SIZE
    message("  fetched ", length(out),
            if (!is.null(total)) paste0(" / ", total) else "")
    if (!is.null(total) && length(out) >= as.integer(total)) break
    if (skip > 5000) break  # safety cap — NV has ~645 DCs
    Sys.sleep(0.5)          # be polite to a state board server
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
  message("Endpoint is LIVE. First record keys:")
  target <- if (length(batch) > 0) batch[[1]] else data
  cat(substr(toJSON(target, auto_unbox = TRUE, pretty = TRUE), 1, 1500), "\n")
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
