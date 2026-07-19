#!/usr/bin/env python3
"""
Merge the NV Board register (pull_nv_board.py) into the master outreach list
(pull_nppes.py) by matching provider names.

Run AFTER both pulls, in this order:
    python3 pull_nppes.py       -> nv-chiropractor-list.csv   (contact backbone)
    python3 pull_nv_board.py    -> nv-board-licensees.csv     (license status)
    python3 merge_lists.py      -> nv-chiropractor-list.csv   (updated in place)

What it does:
  * Fills License_Status on every NPPES row that matches a Board record
    (exact last+first name match, then last name + first initial).
  * Appends Board licensees with NO NPPES match as new rows — these are DCs
    without an individual NPI record (often working under a clinic's group NPI),
    i.e. practices NPPES alone would have missed.
  * Never overwrites contact fields you've already enriched by hand.

A backup of the previous list is saved as nv-chiropractor-list.backup.csv.
"""
import csv
import shutil
import sys

MASTER = "nv-chiropractor-list.csv"
BOARD = "nv-board-licensees.csv"
BACKUP = "nv-chiropractor-list.backup.csv"


def norm(s):
    return "".join(c for c in (s or "").upper().strip() if c.isalpha())


def main():
    try:
        with open(MASTER, newline="") as f:
            reader = csv.DictReader(f)
            master_cols = reader.fieldnames
            master = [row for row in reader]
    except FileNotFoundError:
        sys.exit(f"{MASTER} not found — run pull_nppes.py first.")
    try:
        with open(BOARD, newline="") as f:
            board = list(csv.DictReader(f))
    except FileNotFoundError:
        sys.exit(f"{BOARD} not found — run pull_nv_board.py first.")

    # skip the template's example rows
    master = [r for r in master
              if "EXAMPLE ROW" not in (r.get("Notes") or "")]

    # index master by name
    by_full, by_init = {}, {}
    for r in master:
        last, first = norm(r["DC_LastName"]), norm(r["DC_FirstName"])
        if last:
            by_full.setdefault((last, first), []).append(r)
            if first:
                by_init.setdefault((last, first[0]), []).append(r)

    matched = updated = appended = 0
    for b in board:
        last, first = norm(b["DC_LastName"]), norm(b["DC_FirstName"])
        hits = by_full.get((last, first)) or (
            by_init.get((last, first[0] if first else "")) or [])
        if hits:
            matched += 1
            for r in hits:
                if b.get("License_Status") and r.get("License_Status") != b["License_Status"]:
                    r["License_Status"] = b["License_Status"]
                    updated += 1
                if b.get("License_Number"):
                    note = f"NV lic #{b['License_Number']}"
                    if note not in (r.get("Notes") or ""):
                        r["Notes"] = ((r.get("Notes") or "") + "; " + note).strip("; ")
        else:
            # Board licensee NPPES missed — add as a lead needing enrichment
            row = {c: "" for c in master_cols}
            row.update({
                "Priority": "C",
                "DC_LastName": b["DC_LastName"],
                "DC_FirstName": b["DC_FirstName"],
                "City": b.get("City", ""),
                "State": b.get("State", "") or "NV",
                "License_Status": b.get("License_Status", ""),
                "Bills_Insurance": "Unknown",
                "Segment": "Other NV",
                "Source": "NV Board only",
                "Notes": (f"NV lic #{b.get('License_Number','')}"
                          "; no individual NPI — find clinic to enrich").strip("; "),
            })
            master.append(row)
            appended += 1

    shutil.copy(MASTER, BACKUP)
    with open(MASTER, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=master_cols)
        w.writeheader()
        w.writerows(master)

    inactive = sum(1 for r in master
                   if r.get("License_Status", "").lower()
                   not in ("", "active", "unknown"))
    print(f"Board records matched to master: {matched}")
    print(f"License_Status values updated:   {updated}")
    print(f"Board-only rows appended:        {appended}")
    print(f"Rows now flagged non-active:     {inactive}  "
          "(review before contacting — retired/lapsed DCs are not targets)")
    print(f"\nWrote {MASTER} (backup at {BACKUP})")


if __name__ == "__main__":
    main()
