#!/usr/bin/env python3
"""
Scrape the Chiropractic Physicians' Board of Nevada public licensee register
(Thentia Cloud portal) into a CSV compatible with nv-chiropractor-list.csv.

Run on your own machine:            python3 pull_nv_board.py
If the default endpoint 404s:       python3 pull_nv_board.py --probe
Then follow the instructions probe prints.

Why this works: the register page at
  https://nvcpbn.portalus.thentiacloud.net/webs/portal/register/#/
is a JavaScript app. The data it displays comes from a public JSON API on the
same host (the standard Thentia pattern used by licensing boards nationwide):
  /rest/public/profile/search/?keyword=all&skip=0&take=20&lang=en
This script pages through that API and flattens the results.

This is public record data — NRS 634 requires the Board's roster to be open to
public inspection. Be polite anyway: the script rate-limits between pages.

Output:
  nv-board-licensees.csv  — one row per licensee, template-compatible columns
  nv-board-raw.json       — raw API records, so nothing is lost if the Board's
                            field names don't match the mapping below
"""
import urllib.request
import json
import csv
import time
import sys

BASE = "https://nvcpbn.portalus.thentiacloud.net"
SEARCH = BASE + "/rest/public/profile/search/"
PAGE_SIZE = 100
HEADERS = {
    # A normal browser UA — some WAFs reject default urllib
    "User-Agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                   "AppleWebKit/537.36 (KHTML, like Gecko) "
                   "Chrome/126.0 Safari/537.36"),
    "Accept": "application/json",
    "Referer": BASE + "/webs/portal/register/",
}

# Thentia field names vary slightly per board; every observed variant is listed.
# The REGISTER_PROFILE_LABEL_* names are Nevada's columnLayout labels, applied
# when the API returns positional rows (see extract_batch).
FIELD_MAP = {
    "last":    ["REGISTER_PROFILE_LABEL_LAST_NAME", "lastName", "last_name",
                "surname"],
    "first":   ["REGISTER_PROFILE_LABEL_FIRST_NAME", "firstName", "first_name",
                "givenName"],
    "license": ["REGISTER_PROFILE_LABEL_LICENSE_NUMBER", "licenseNumber",
                "license_number", "registrationNumber", "licenceNumber"],
    "status":  ["REGISTER_PROFILE_LABEL_LICENSE_STATUS", "status",
                "licenseStatus", "registrationStatus"],
    "type":    ["REGISTER_PROFILE_LABEL_LICENSE_TYPE", "licenseType",
                "license_type", "registrationType", "profession"],
    "city":    ["REGISTER_PROFILE_LABEL_CITY", "city", "addressCity",
                "practiceCity"],
    "state":   ["state", "province", "addressState"],
    "expiry":  ["REGISTER_PROFILE_LABEL_LICENSE_EXPIRY_DATE", "expiryDate",
                "expirationDate", "expiry"],
    "id":      ["id", "profileId", "entityId"],
}


def get(url):
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def pick(rec, keys):
    for k in keys:
        v = rec.get(k)
        if v not in (None, ""):
            return str(v).strip()
    return ""


def extract_batch(data):
    """Normalize the three Thentia response shapes to a list of keyed records:
    a bare list, {"result": [...]}, or (Nevada's) {"result": {"dataResults":
    [...], "columnLayout": [...]}} where rows are positional arrays."""
    if isinstance(data, list):
        return data
    res = data.get("result")
    if isinstance(res, dict) and "dataResults" in res:
        layout = res.get("columnLayout") or []
        out = []
        for row in res.get("dataResults") or []:
            if isinstance(row, dict):
                out.append(row)
            elif isinstance(row, list) and len(row) == len(layout):
                out.append({k: ("" if v is None else v)
                            for k, v in zip(layout, row)})
            else:
                out.append(row)
        return out
    return data.get("results") or data.get("data") or (
        res if isinstance(res, list) else [])


def fetch_keyword(keyword):
    """Page through the search API for one keyword until it runs dry."""
    out, skip = [], 0
    while True:
        url = f"{SEARCH}?keyword={keyword}&skip={skip}&take={PAGE_SIZE}&lang=en"
        data = get(url)
        batch = extract_batch(data)
        if not batch:
            break
        out.extend(batch)
        total = None if isinstance(data, list) else data.get("resultCount")
        skip += PAGE_SIZE
        if total is not None and len(out) >= int(total):
            break
        if skip > 5000:  # safety cap — NV has ~645 DCs
            break
        time.sleep(0.5)  # be polite to a state board server
    return out


def rec_key(rec):
    """Dedupe key: license number, else id, else full name."""
    k = pick(rec, FIELD_MAP["license"]) or pick(rec, FIELD_MAP["id"]) or (
        pick(rec, FIELD_MAP["last"]) + " " + pick(rec, FIELD_MAP["first"]))
    return k.upper()


def fetch_all():
    # Some Thentia tenants return everything for keyword=all; others (including
    # Nevada's) return an empty set for it. Try "all" first, then fall back to
    # sweeping a-z — every name contains at least one letter — and dedupe.
    out = fetch_keyword("all")
    if out:
        print(f"  fetched {len(out)} via keyword=all", file=sys.stderr)
        return out
    print("  keyword=all returned nothing; sweeping a-z instead",
          file=sys.stderr)
    seen = set()
    for letter in "abcdefghijklmnopqrstuvwxyz":
        batch = fetch_keyword(letter)
        fresh = 0
        for rec in batch:
            k = rec_key(rec)
            if k not in seen:
                seen.add(k)
                out.append(rec)
                fresh += 1
        print(f"  keyword={letter}: {len(batch)} records "
              f"({fresh} new, total {len(out)})", file=sys.stderr)
        time.sleep(0.5)
    return out


def probe():
    url = f"{SEARCH}?keyword=all&skip=0&take=2&lang=en"
    print(f"Probing {url}\n", file=sys.stderr)
    try:
        data = get(url)
    except Exception as e:
        print(f"Endpoint failed: {e}\n\n"
              "Find the real endpoint in 30 seconds:\n"
              "  1. Open the register page in Chrome:\n"
              f"     {BASE}/webs/portal/register/#/\n"
              "  2. Press F12 -> Network tab -> filter 'Fetch/XHR'\n"
              "  3. Click Search on the page (leave the box empty or type 'all')\n"
              "  4. The request that returns licensee JSON is your endpoint —\n"
              "     copy its URL into SEARCH at the top of this script.\n",
              file=sys.stderr)
        return
    batch = extract_batch(data)
    if not batch:
        print("Endpoint is LIVE but keyword=all returns nothing on this "
              "tenant.\nTrying keyword=s to sample a real record...\n",
              file=sys.stderr)
        try:
            data = get(f"{SEARCH}?keyword=s&skip=0&take=2&lang=en")
            batch = extract_batch(data)
        except Exception as e:
            print(f"Sample query failed too: {e}", file=sys.stderr)
            return
        if not batch:
            print("Still empty — the search likely needs different "
                  "parameters.\nOpen the register page in Chrome, press F12 "
                  "-> Network -> Fetch/XHR,\nrun a search, and copy the URL "
                  "of the licensee JSON request into SEARCH.", file=sys.stderr)
            return
        print("Sample worked — main() will sweep a-z automatically.",
              file=sys.stderr)
    else:
        print("Endpoint is LIVE. First record keys:", file=sys.stderr)
    if batch:
        print(json.dumps(batch[0], indent=2)[:1500])
    else:
        print(json.dumps(data, indent=2)[:1500])


def main():
    if "--probe" in sys.argv:
        probe()
        return
    print("Pulling NV Board licensee register...", file=sys.stderr)
    records = fetch_all()
    print(f"Total records: {len(records)}", file=sys.stderr)
    if not records:
        print("No records returned — run with --probe to diagnose.", file=sys.stderr)
        return

    with open("nv-board-raw.json", "w") as f:
        json.dump(records, f, indent=2)

    cols = ["DC_LastName", "DC_FirstName", "License_Number", "License_Status",
            "License_Type", "City", "State", "License_Expiry", "Board_Profile_Id",
            "Source"]
    kept = 0
    with open("nv-board-licensees.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        for rec in records:
            ltype = pick(rec, FIELD_MAP["type"])
            # keep DCs; skip chiropractic assistants unless you want them too
            if ltype and "assist" in ltype.lower():
                continue
            w.writerow({
                "DC_LastName": pick(rec, FIELD_MAP["last"]),
                "DC_FirstName": pick(rec, FIELD_MAP["first"]),
                "License_Number": pick(rec, FIELD_MAP["license"]),
                "License_Status": pick(rec, FIELD_MAP["status"]),
                "License_Type": ltype,
                "City": pick(rec, FIELD_MAP["city"]),
                "State": pick(rec, FIELD_MAP["state"]),
                "License_Expiry": pick(rec, FIELD_MAP["expiry"]),
                "Board_Profile_Id": pick(rec, FIELD_MAP["id"]),
                "Source": "NV Board (Thentia)",
            })
            kept += 1
    print(f"Wrote nv-board-licensees.csv ({kept} DCs) and nv-board-raw.json",
          file=sys.stderr)
    print("\nNext: python3 merge_lists.py  — folds license status into "
          "nv-chiropractor-list.csv", file=sys.stderr)


if __name__ == "__main__":
    main()
