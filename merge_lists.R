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
      for (j in hits) {
        if (nzchar(b_status) && master$License_Status[j] != b_status) {
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
      }
    } else {
      # Board licensee NPPES missed — add as a lead needing enrichment
      row <- setNames(as.list(rep("", ncol(master))), names(master))
      row$Priority        <- "C"
      row$DC_LastName     <- val(board, i, "DC_LastName")
      row$DC_FirstName    <- val(board, i, "DC_FirstName")
      row$City            <- val(board, i, "City")
      row$State           <- if (nzchar(val(board, i, "State")))
                               val(board, i, "State") else "NV"
      row$License_Status  <- val(board, i, "License_Status")
      row$Bills_Insurance <- "Unknown"
      row$Segment         <- "Other NV"
      row$Source          <- "NV Board only"
      lic <- val(board, i, "License_Number")
      row$Notes <- sub("^; ", "", paste0(
        if (nzchar(lic)) paste0("NV lic #", lic) else "",
        "; no individual NPI — find clinic to enrich"))
      new_rows[[length(new_rows) + 1]] <-
        as.data.frame(row, stringsAsFactors = FALSE, check.names = FALSE)
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
  cat("Board-only rows appended:       ", length(new_rows), "\n")
  cat("Rows now flagged non-active:    ", inactive,
      " (review before contacting — retired/lapsed DCs are not targets)\n")
  cat("\nWrote", MASTER, "(backup at", paste0(BACKUP, ")"), "\n")
}

main()
