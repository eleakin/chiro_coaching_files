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


CLARK = {"LAS VEGAS", "HENDERSON", "NORTH LAS VEGAS", "BOULDER CITY",
         "MESQUITE", "LAUGHLIN"}
WASHOE = {"RENO", "SPARKS", "INCLINE VILLAGE"}

# status priority: a person can match several board records (old expired
# license + current active one) — the best status must win, never the one
# that happens to be processed last
STATUS_ORDER = ["active", "suspended", "inactive", "delinquent", "expired",
                "retired", "revoked"]


def status_rank(s):
    s = (s or "").lower()
    return STATUS_ORDER.index(s) if s in STATUS_ORDER else 99


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

    matched = updated = appended = skipped_ghosts = 0
    for b in board:
        last, first = norm(b["DC_LastName"]), norm(b["DC_FirstName"])
        hits = by_full.get((last, first)) or (
            by_init.get((last, first[0] if first else "")) or [])
        b_status = b.get("License_Status") or ""
        if hits:
            matched += 1
            for r in hits:
                cur = r.get("License_Status") or ""
                # only upgrade: better-ranked status wins regardless of order
                if (b_status and cur != b_status
                        and status_rank(b_status) < status_rank(cur)):
                    r["License_Status"] = b_status
                    updated += 1
                if b.get("License_Number"):
                    note = f"NV lic #{b['License_Number']}"
                    if note not in (r.get("Notes") or ""):
                        r["Notes"] = ((r.get("Notes") or "") + "; " + note).strip("; ")
                if (b.get("Disciplinary_Action") or "").lower() in ("yes", "true", "y"):
                    note = "disciplinary action on record"
                    if note not in (r.get("Notes") or ""):
                        r["Notes"] = ((r.get("Notes") or "") + "; " + note).strip("; ")
        elif b_status.lower() == "active":
            # Active board licensee NPPES missed — a real lead needing
            # enrichment. Non-active unmatched licensees are skipped:
            # appending ~900 expired/revoked ghosts would just pad the list.
            city_up = (b.get("City") or "").upper()
            segment = ("Clark (Vegas/Henderson)" if city_up in CLARK
                       else "Washoe (Reno/Sparks)" if city_up in WASHOE
                       else "Other NV")
            row = {c: "" for c in master_cols}
            row.update({
                "Priority": "C",
                "DC_LastName": b["DC_LastName"],
                "DC_FirstName": b["DC_FirstName"],
                "City": b.get("City", ""),
                "State": "NV",
                "License_Status": b_status,
                "Bills_Insurance": "Unknown",
                "Segment": segment,
                "Source": "NV Board only",
                "Notes": (f"NV lic #{b.get('License_Number','')}"
                          "; no individual NPI — find clinic to enrich").strip("; "),
            })
            master.append(row)
            appended += 1
        else:
            skipped_ghosts += 1

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
    print(f"Active board-only rows appended: {appended}")
    print(f"Non-active unmatched skipped:    {skipped_ghosts}")
    print(f"Rows now flagged non-active:     {inactive}  "
          "(review before contacting — retired/lapsed DCs are not targets)")
    print(f"\nWrote {MASTER} (backup at {BACKUP})")


if __name__ == "__main__":
    main()
