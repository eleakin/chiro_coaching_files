# pull_nv_board.R ------------------------------------------------------------
# Scrape the Chiropractic Physicians' Board of Nevada public licensee register
# (Thentia Cloud portal) into a CSV compatible with nv-chiropractor-list.csv.
#
# Run on your own machine:        Rscript pull_nv_board.R
# To test the endpoint first:     Rscript pull_nv_board.R --probe
# One-time setup:                 install.packages(c("httr", "jsonlite"))
#
# The register page (https://nvcpbn.portalus.thentiacloud.net/webs/portal/
# register/#/) is a JavaScript app backed by a public JSON API. Captured from
# the page's own network traffic, the real search request is:
#   /rest/public/profile/search/?keyword=smith&skip=0&take=20&lang=en-us
#     &licenseType=Chiropractic%20Physician&licenseStatus=Active
#     &disciplined=false
# The licenseType/licenseStatus/disciplined filters are REQUIRED — without
# them the API answers with an empty result set. Responses arrive as
# {result: {dataResults: [[...], ...], columnLayout: [...]}} with positional
# rows aligned to columnLayout.
#
# This is public record data — NRS 634 requires the Board's roster to be open
# to public inspection. Be polite anyway: the script rate-limits requests.
#
# Output:
#   nv-board-licensees.csv  one row per licensee
#   nv-board-raw.json       raw API records, in case field mapping ever drifts

library(httr)
library(jsonlite)

BASE         <- "https://nvcpbn.portalus.thentiacloud.net"
SEARCH       <- paste0(BASE, "/rest/public/profile/search/")
PAGE_SIZE    <- 100
LICENSE_TYPE <- "Chiropractic Physician"

# "Active" is confirmed live from the page. The others are common Thentia
# status values tried opportunistically — a wrong guess just returns 0 rows.
STATUSES <- c("Active", "Inactive", "Expired", "Suspended", "Revoked",
              "Delinquent", "Retired")

HEADERS <- add_headers(
  # a normal browser UA — the portal's firewall rejects bare clients
  `User-Agent` = paste0("Mozilla/5.0 (Windows NT 10.0; Win64; x64) ",
                        "AppleWebKit/537.36 (KHTML, like Gecko) ",
                        "Chrome/126.0 Safari/537.36"),
  Accept    = "application/json",
  Referer   = paste0(BASE, "/webs/portal/register/")
)

# Nevada returns positional rows keyed by these columnLayout labels
# (extract_batch applies them); the other variants cover Thentia tenants
# that return keyed objects directly.
FIELD_MAP <- list(
  last    = c("REGISTER_PROFILE_LABEL_LAST_NAME", "lastName", "last_name"),
  first   = c("REGISTER_PROFILE_LABEL_FIRST_NAME", "firstName", "first_name"),
  license = c("REGISTER_PROFILE_LABEL_LICENSE_NUMBER", "licenseNumber",
              "license_number"),
  status  = c("REGISTER_PROFILE_LABEL_LICENSE_STATUS", "status",
              "licenseStatus"),
  type    = c("REGISTER_PROFILE_LABEL_LICENSE_TYPE", "licenseType",
              "license_type"),
  city    = c("REGISTER_PROFILE_LABEL_CITY", "city"),
  expiry  = c("REGISTER_PROFILE_LABEL_LICENSE_EXPIRY_DATE", "expiryDate",
              "expirationDate"),
  disc    = c("REGISTER_PROFILE_LABEL_DISCIPLINARY_ACTION",
              "disciplinaryAction"),
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

# Normalize the three Thentia response shapes to a list of keyed records:
# a bare list, {result: [...]}, or Nevada's {result: {dataResults: [...],
# columnLayout: [...]}} where each row is a positional array.
extract_batch <- function(data) {
  if (is.null(names(data))) return(data)
  res <- data$result
  if (!is.null(res) && !is.null(names(res)) && !is.null(res$dataResults)) {
    layout <- unlist(res$columnLayout)
    return(lapply(res$dataResults, function(row) {
      if (!is.null(names(row))) return(row)
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

build_url <- function(keyword, status, disciplined, skip, take) {
  paste0(SEARCH,
         "?keyword=", URLencode(keyword, reserved = TRUE),
         "&skip=", skip, "&take=", take,
         "&lang=en-us",
         "&licenseType=", URLencode(LICENSE_TYPE, reserved = TRUE),
         "&licenseStatus=", URLencode(status, reserved = TRUE),
         "&disciplined=", disciplined)
}

fetch_keyword <- function(keyword, status, disciplined) {
  out <- list()
  skip <- 0
  repeat {
    data <- get_json(build_url(keyword, status, disciplined, skip, PAGE_SIZE))
    batch <- extract_batch(data)
    if (length(batch) == 0) break
    out <- c(out, batch)
    total <- if (is.null(names(data))) NULL else data$resultCount
    skip <- skip + PAGE_SIZE
    if (!is.null(total) && length(out) >= as.integer(total)) break
    if (skip > 5000) break  # safety cap — NV has ~645 DCs
    Sys.sleep(0.4)          # be polite to a state board server
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
  out <- list()
  seen <- character(0)
  add_records <- function(batch) {
    fresh <- 0
    for (rec in batch) {
      k <- rec_key(rec)
      if (!(k %in% seen)) {
        seen <<- c(seen, k)
        out[[length(out) + 1]] <<- rec
        fresh <- fresh + 1
      }
    }
    fresh
  }

  for (disciplined in c("false", "true")) {
    for (status in STATUSES) {
      batch <- tryCatch(fetch_keyword("all", status, disciplined),
                        error = function(e) list())
      if (length(batch) > 0) {
        fresh <- add_records(batch)
        message("  ", status, " / disciplined=", disciplined,
                " keyword=all: ", length(batch), " records (",
                fresh, " new, total ", length(out), ")")
        next
      }
      # keyword=all may be a dud on this tenant — sweep a-z, but only for
      # Active (the speculative statuses aren't worth 26 extra requests each)
      if (status != "Active") next
      message("  ", status, " / disciplined=", disciplined,
              ": keyword=all empty; sweeping a-z")
      for (letter in letters) {
        batch <- tryCatch(fetch_keyword(letter, status, disciplined),
                          error = function(e) list())
        fresh <- add_records(batch)
        if (length(batch) > 0)
          message("    keyword=", letter, ": ", length(batch), " records (",
                  fresh, " new, total ", length(out), ")")
        Sys.sleep(0.4)
      }
    }
  }
  out
}

probe <- function() {
  url <- build_url("smith", "Active", "false", 0, 3)
  message("Probing ", url, "\n")
  data <- tryCatch(get_json(url), error = function(e) e)
  if (inherits(data, "error")) {
    message("Endpoint failed: ", conditionMessage(data), "\n",
      "Re-capture the request URL from the register page (F12 -> Network ->\n",
      "Fetch/XHR -> search on the page) and update SEARCH/build_url above.")
    return(invisible(NULL))
  }
  batch <- extract_batch(data)
  if (length(batch) == 0) {
    message("Endpoint answered but returned 0 records for keyword=smith —\n",
            "the filter parameters have likely changed. Re-capture the URL\n",
            "from the register page (F12 -> Network -> Fetch/XHR).")
    return(invisible(NULL))
  }
  message("Endpoint is LIVE — sample record:")
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
  message("Total unique records: ", length(records))
  if (length(records) == 0) {
    message("No records returned — run probe() to diagnose.")
    return(invisible(NULL))
  }

  write(toJSON(records, auto_unbox = TRUE, pretty = TRUE), "nv-board-raw.json")

  rows <- lapply(records, function(rec) {
    data.frame(
      DC_LastName         = pick(rec, FIELD_MAP$last),
      DC_FirstName        = pick(rec, FIELD_MAP$first),
      License_Number      = pick(rec, FIELD_MAP$license),
      License_Status      = pick(rec, FIELD_MAP$status),
      License_Type        = pick(rec, FIELD_MAP$type),
      City                = pick(rec, FIELD_MAP$city),
      State               = "NV",
      License_Expiry      = pick(rec, FIELD_MAP$expiry),
      Disciplinary_Action = pick(rec, FIELD_MAP$disc),
      Board_Profile_Id    = pick(rec, FIELD_MAP$id),
      Source              = "NV Board (Thentia)",
      stringsAsFactors    = FALSE
    )
  })
  df <- do.call(rbind, rows)

  write.csv(df, "nv-board-licensees.csv", row.names = FALSE, na = "")
  message("Wrote nv-board-licensees.csv (", nrow(df),
          " licensees) and nv-board-raw.json")
  message("\nNext: source(\"merge_lists.R\") — folds license status into ",
          "nv-chiropractor-list.csv")
}

main()
