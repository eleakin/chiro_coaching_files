# pull_nppes.R ---------------------------------------------------------------
# Pull every Nevada chiropractor from the CMS NPPES NPI Registry into a CSV
# matching the ELE list template.
#
# Run on your own machine:   Rscript pull_nppes.R
# One-time setup:            install.packages(c("httr", "jsonlite"))
# Output:                    nv-chiropractor-list.csv
#
# NPPES is the free, official federal provider registry. Taxonomy 111N00000X =
# Chiropractor. This gets name, practice address, phone, and NPI for the whole
# state. You then enrich (email, website, license status, insurance-billing
# flag) per list-building-guide.md.

library(httr)
library(jsonlite)

BASE <- "https://npiregistry.cms.hhs.gov/api/"
CLARK <- c("LAS VEGAS", "HENDERSON", "NORTH LAS VEGAS", "BOULDER CITY",
           "MESQUITE", "LAUGHLIN")
WASHOE <- c("RENO", "SPARKS", "INCLINE VILLAGE")

COLS <- c("Priority", "DC_LastName", "DC_FirstName", "Clinic_Name", "City",
          "County", "State", "Practice_Address", "Postal", "Phone", "Email",
          "Website", "LinkedIn_URL", "NPI", "License_Status", "Bills_Insurance",
          "Cash_Only_Flag", "Segment", "Est_Monthly_Claims", "Source",
          "Touch1_Date", "Touch2_Date", "Touch3_Date", "LinkedIn_Connected",
          "Letter_Mailed", "Replied", "Review_Sent", "Founding_Client",
          "Outcome", "OptOut", "Notes")

# safe field getter: "" when missing/NULL
pick <- function(x, key) {
  v <- x[[key]]
  if (is.null(v) || length(v) == 0) "" else trimws(as.character(v)[1])
}

pull_all <- function() {
  records <- list()
  skip <- 0
  repeat {
    resp <- GET(BASE, query = list(
      version = "2.1",
      taxonomy_description = "Chiropractor",
      state = "NV",
      country_code = "US",
      limit = 200,
      skip = skip
    ), timeout(30))
    if (http_error(resp)) {
      message("Network error: HTTP ", status_code(resp))
      break
    }
    data <- fromJSON(content(resp, as = "text", encoding = "UTF-8"),
                     simplifyVector = FALSE)
    results <- data$results
    if (is.null(results) || length(results) == 0) break
    records <- c(records, results)
    skip <- skip + 200
    message("  fetched ", length(records))
    if (length(results) < 200 || skip > 4000) break  # safety cap
    Sys.sleep(0.3)
  }
  records
}

main <- function() {
  raw <- pull_all()
  message("Pulled ", length(raw), " provider records from NPPES")

  rows <- lapply(raw, function(it) {
    basic <- if (is.null(it$basic)) list() else it$basic
    addrs <- if (is.null(it$addresses)) list() else it$addresses
    # prefer the practice LOCATION address
    addr <- list()
    if (length(addrs) > 0) {
      addr <- addrs[[1]]
      for (a in addrs) {
        if (identical(pick(a, "address_purpose"), "LOCATION")) {
          addr <- a
          break
        }
      }
    }
    city <- toupper(pick(addr, "city"))
    seg <- if (city %in% CLARK) "Clark (Vegas/Henderson)"
           else if (city %in% WASHOE) "Washoe (Reno/Sparks)"
           else "Other NV"
    cnty <- if (city %in% CLARK) "Clark"
            else if (city %in% WASHOE) "Washoe"
            else ""
    address <- trimws(paste(pick(addr, "address_1"), pick(addr, "address_2")))

    out <- setNames(as.list(rep("", length(COLS))), COLS)
    out$DC_LastName      <- pick(basic, "last_name")
    out$DC_FirstName     <- pick(basic, "first_name")
    out$Clinic_Name      <- pick(basic, "organization_name")
    out$City             <- pick(addr, "city")
    out$County           <- cnty
    out$State            <- pick(addr, "state")
    out$Practice_Address <- address
    out$Postal           <- substr(pick(addr, "postal_code"), 1, 5)
    out$Phone            <- pick(addr, "telephone_number")
    out$NPI              <- pick(it, "number")
    out$Segment          <- seg
    out$Source           <- "NPPES"
    out$Notes            <- if (identical(pick(it, "enumeration_type"), "NPI-2"))
                              "org record" else ""
    as.data.frame(out, stringsAsFactors = FALSE)
  })

  df <- do.call(rbind, rows)
  write.csv(df, "nv-chiropractor-list.csv", row.names = FALSE, na = "")
  message("Wrote nv-chiropractor-list.csv (", nrow(df), " rows)")
}

main()
