# merge_lists.R --------------------------------------------------------------
# Merge the NV Board register (pull_nv_board.R) into the master outreach list
# (pull_nppes.R) by matching provider names.
#
# Run AFTER both pulls, in this order:
#   Rscript pull_nppes.R      -> nv-chiropractor-list.csv   (contact backbone)
#   Rscript pull_nv_board.R   -> nv-board-licensees.csv     (license status)
#   Rscript merge_lists.R     -> nv-chiropractor-list.csv   (updated in place)
#
# What it does:
#   * Fills License_Status on every NPPES row that matches a Board record
#     (exact last+first name match, then last name + first initial).
#   * Appends Board licensees with NO NPPES match as new rows — these are DCs
#     without an individual NPI record (often working under a clinic's group
#     NPI), i.e. practices NPPES alone would have missed.
#   * Never overwrites contact fields you've already enriched by hand.
#
# A backup of the previous list is saved as nv-chiropractor-list.backup.csv.

MASTER <- "nv-chiropractor-list.csv"
BOARD  <- "nv-board-licensees.csv"
BACKUP <- "nv-chiropractor-list.backup.csv"

# normalize a name: uppercase, letters only
norm <- function(s) {
  s <- ifelse(is.na(s), "", s)
  gsub("[^A-Z]", "", toupper(trimws(s)))
}

# status priority: a person can match several board records (old expired
# license + current active one) — the best status must win, never the one
# that happens to be processed last
status_rank <- function(s) {
  r <- match(tolower(s), c("active", "suspended", "inactive", "delinquent",
                           "expired", "retired", "revoked"))
  ifelse(is.na(r), 99L, r)
}

# empty-string-safe getter for data.frame rows
val <- function(df, i, col) {
  v <- df[[col]][i]
  if (is.na(v)) "" else as.character(v)
}

main <- function() {
  if (!file.exists(MASTER))
    stop(MASTER, " not found — run pull_nppes.R first.", call. = FALSE)
  if (!file.exists(BOARD))
    stop(BOARD, " not found — run pull_nv_board.R first.", call. = FALSE)

  master <- read.csv(MASTER, stringsAsFactors = FALSE, check.names = FALSE,
                     colClasses = "character")
  board  <- read.csv(BOARD, stringsAsFactors = FALSE, check.names = FALSE,
                     colClasses = "character")
  master[is.na(master)] <- ""
  board[is.na(board)]   <- ""

  # skip the template's example rows
  master <- master[!grepl("EXAMPLE ROW", master$Notes, fixed = TRUE), ,
                   drop = FALSE]

  m_last  <- norm(master$DC_LastName)
  m_first <- norm(master$DC_FirstName)
  m_full  <- paste(m_last, m_first, sep = "|")
  m_init  <- paste(m_last, substr(m_first, 1, 1), sep = "|")

  matched <- 0
  updated <- 0
  skipped_ghosts <- 0
  new_rows <- list()

  for (i in seq_len(nrow(board))) {
    b_last  <- norm(board$DC_LastName[i])
    b_first <- norm(board$DC_FirstName[i])
    if (!nzchar(b_last)) next

    hits <- which(m_full == paste(b_last, b_first, sep = "|"))
    if (length(hits) == 0)
      hits <- which(m_init == paste(b_last, substr(b_first, 1, 1), sep = "|"))

    if (length(hits) > 0) {
      matched <- matched + 1
      b_status <- val(board, i, "License_Status")
      b_lic    <- val(board, i, "License_Number")
      b_disc   <- val(board, i, "Disciplinary_Action")
      for (j in hits) {
        cur <- master$License_Status[j]
        # only upgrade: better-ranked status wins regardless of record order
        if (nzchar(b_status) && cur != b_status &&
            status_rank(b_status) < status_rank(cur)) {
          master$License_Status[j] <- b_status
          updated <- updated + 1
        }
        if (nzchar(b_lic)) {
          note <- paste0("NV lic #", b_lic)
          if (!grepl(note, master$Notes[j], fixed = TRUE)) {
            master$Notes[j] <- sub("^; ", "",
                                   paste(master$Notes[j], note, sep = "; "))
          }
        }
        if (tolower(b_disc) %in% c("yes", "true", "y")) {
          if (!grepl("disciplinary action on record", master$Notes[j],
                     fixed = TRUE)) {
            master$Notes[j] <- sub("^; ", "",
              paste(master$Notes[j], "disciplinary action on record",
                    sep = "; "))
          }
        }
      }
    } else if (tolower(val(board, i, "License_Status")) == "active") {
      # Active board licensee NPPES missed — a real lead needing enrichment.
      # Non-active unmatched licensees are skipped: appending ~900
      # expired/revoked ghosts would just pad the list with junk rows.
      city_up <- toupper(val(board, i, "City"))
      row <- setNames(as.list(rep("", ncol(master))), names(master))
      row$Priority        <- "C"
      row$DC_LastName     <- val(board, i, "DC_LastName")
      row$DC_FirstName    <- val(board, i, "DC_FirstName")
      row$City            <- val(board, i, "City")
      row$State           <- "NV"
      row$License_Status  <- val(board, i, "License_Status")
      row$Bills_Insurance <- "Unknown"
      row$Segment         <- if (city_up %in% c("LAS VEGAS", "HENDERSON",
                                 "NORTH LAS VEGAS", "BOULDER CITY",
                                 "MESQUITE", "LAUGHLIN"))
                               "Clark (Vegas/Henderson)"
                             else if (city_up %in% c("RENO", "SPARKS",
                                      "INCLINE VILLAGE"))
                               "Washoe (Reno/Sparks)"
                             else "Other NV"
      row$Source          <- "NV Board only"
      lic <- val(board, i, "License_Number")
      row$Notes <- sub("^; ", "", paste0(
        if (nzchar(lic)) paste0("NV lic #", lic) else "",
        "; no individual NPI — find clinic to enrich"))
      new_rows[[length(new_rows) + 1]] <-
        as.data.frame(row, stringsAsFactors = FALSE, check.names = FALSE)
    } else {
      skipped_ghosts <- skipped_ghosts + 1
    }
  }

  if (length(new_rows) > 0)
    master <- rbind(master, do.call(rbind, new_rows))

  file.copy(MASTER, BACKUP, overwrite = TRUE)
  write.csv(master, MASTER, row.names = FALSE, na = "")

  inactive <- sum(!tolower(master$License_Status) %in%
                    c("", "active", "unknown"))
  cat("Board records matched to master:", matched, "\n")
  cat("License_Status values updated:  ", updated, "\n")
  cat("Active board-only rows appended:", length(new_rows), "\n")
  cat("Non-active unmatched skipped:   ", skipped_ghosts, "\n")
  cat("Rows now flagged non-active:    ", inactive,
      " (review before contacting — retired/lapsed DCs are not targets)\n")
  cat("\nWrote", MASTER, "(backup at", paste0(BACKUP, ")"), "\n")
}

main()
