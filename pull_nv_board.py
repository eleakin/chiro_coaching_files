#!/usr/bin/env python3
"""
Scrape the Chiropractic Physicians' Board of Nevada public licensee register
(Thentia Cloud portal) into a CSV compatible with nv-chiropractor-list.csv.

Run on your own machine:            python3 pull_nv_board.py
To test the endpoint first:         python3 pull_nv_board.py --probe

The register page (https://nvcpbn.portalus.thentiacloud.net/webs/portal/
register/#/) is a JavaScript app backed by a public JSON API. Captured from
the page's own network traffic, the real search request is:
  /rest/public/profile/search/?keyword=smith&skip=0&take=20&lang=en-us
    &licenseType=Chiropractic%20Physician&licenseStatus=Active
    &disciplined=false
The licenseType/licenseStatus/disciplined filters are REQUIRED — without them
the API answers with an empty result set. Responses arrive as
{result: {dataResults: [[...], ...], columnLayout: [...]}} with positional
rows aligned to columnLayout.

This is public record data — NRS 634 requires the Board's roster to be open to
public inspection. Be polite anyway: the script rate-limits requests.

Output:
  nv-board-licensees.csv  — one row per licensee
  nv-board-raw.json       — raw API records, in case field mapping ever drifts
"""
import urllib.request
import urllib.parse
import json
import csv
import time
import sys

BASE = "https://nvcpbn.portalus.thentiacloud.net"
SEARCH = BASE + "/rest/public/profile/search/"
PAGE_SIZE = 100
LICENSE_TYPE = "Chiropractic Physician"

# "Active" is confirmed live from the page. The others are common Thentia
# status values tried opportunistically — a wrong guess just returns 0 rows.
STATUSES = ["Active", "Inactive", "Expired", "Suspended", "Revoked",
            "Delinquent", "Retired"]

HEADERS = {
    # a normal browser UA — the portal's firewall rejects bare clients
    "User-Agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                   "AppleWebKit/537.36 (KHTML, like Gecko) "
                   "Chrome/126.0 Safari/537.36"),
    "Accept": "application/json",
    "Referer": BASE + "/webs/portal/register/",
}

# Nevada returns rows as {id, columnValues: [{data, type}, ...]} aligned to
# columnLayout; extract_batch flattens them to records keyed by these labels.
# QUERY_STATUS / QUERY_DISCIPLINED are stamped from the query parameters at
# fetch time — ground truth, immune to lookup-token values in the columns.
FIELD_MAP = {
    "last":    ["REGISTER_PROFILE_LABEL_LAST_NAME", "lastName", "last_name"],
    "first":   ["REGISTER_PROFILE_LABEL_FIRST_NAME", "firstName",
                "first_name"],
    "license": ["REGISTER_PROFILE_LABEL_LICENSE_NUMBER", "licenseNumber",
                "license_number"],
    "status":  ["QUERY_STATUS", "REGISTER_PROFILE_LABEL_LICENSE_STATUS",
                "status", "licenseStatus"],
    "type":    ["REGISTER_PROFILE_LABEL_LICENSE_TYPE", "licenseType",
                "license_type"],
    "city":    ["REGISTER_PROFILE_LABEL_CITY", "city"],
    "expiry":  ["REGISTER_PROFILE_LABEL_LICENSE_EXPIRY_DATE", "expiryDate",
                "expirationDate"],
    "disc":    ["QUERY_DISCIPLINED",
                "REGISTER_PROFILE_LABEL_DISCIPLINARY_ACTION",
                "disciplinaryAction"],
    "id":      ["id", "profileId", "entityId"],
}


def pick(rec, keys):
    for k in keys:
        v = rec.get(k)
        if v not in (None, ""):
            return str(v).strip()
    return ""


def get(url):
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def extract_batch(data):
    """Normalize the Thentia response shapes to a list of keyed records.
    Nevada's rows are {id, columnValues: [{data, type}, ...]} with values
    positionally aligned to columnLayout."""
    if isinstance(data, list):
        return data
    res = data.get("result")
    if isinstance(res, dict) and "dataResults" in res:
        layout = res.get("columnLayout") or []
        out = []
        for row in res.get("dataResults") or []:
            if isinstance(row, dict) and "columnValues" in row:
                vals = [(cv or {}).get("data") or ""
                        for cv in row.get("columnValues") or []]
                rec = dict(zip(layout, vals))
                rec["id"] = row.get("id", "")
                out.append(rec)
            elif isinstance(row, dict):
                out.append(row)
            elif isinstance(row, list) and len(row) == len(layout):
                out.append({k: ("" if v is None else v)
                            for k, v in zip(layout, row)})
            else:
                out.append(row)
        return out
    return data.get("results") or data.get("data") or (
        res if isinstance(res, list) else [])


def build_url(keyword, status, disciplined, skip, take):
    params = urllib.parse.urlencode({
        "keyword": keyword, "skip": skip, "take": take, "lang": "en-us",
        "licenseType": LICENSE_TYPE, "licenseStatus": status,
        "disciplined": disciplined,
    })
    return f"{SEARCH}?{params}"


def fetch_keyword(keyword, status, disciplined):
    out, skip = [], 0
    while True:
        data = get(build_url(keyword, status, disciplined, skip, PAGE_SIZE))
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
        time.sleep(0.4)  # be polite to a state board server
    return out


def rec_key(rec):
    """Dedupe key: license number, else id, else full name."""
    k = pick(rec, FIELD_MAP["license"]) or pick(rec, FIELD_MAP["id"]) or (
        pick(rec, FIELD_MAP["last"]) + " " + pick(rec, FIELD_MAP["first"]))
    return k.upper()


def fetch_all():
    out, seen = [], set()

    def add_records(batch, status, disciplined):
        # stamp each record with the query's status/disciplined — ground
        # truth for fields whose column values may be lookup tokens
        fresh = 0
        for rec in batch:
            k = rec_key(rec)
            if k not in seen:
                seen.add(k)
                rec["QUERY_STATUS"] = status
                rec["QUERY_DISCIPLINED"] = ("Yes" if disciplined == "true"
                                            else "No")
                out.append(rec)
                fresh += 1
        return fresh

    # disciplined=true FIRST: disciplined=false is a superset (it means
    # "don't filter", not "non-disciplined only"), so the disciplined stamp
    # must land before the dedupe sees those records again
    for disciplined in ("true", "false"):
        for status in STATUSES:
            try:
                batch = fetch_keyword("all", status, disciplined)
            except Exception:
                batch = []
            if batch:
                fresh = add_records(batch, status, disciplined)
                print(f"  {status} / disciplined={disciplined} keyword=all: "
                      f"{len(batch)} records ({fresh} new, total {len(out)})",
                      file=sys.stderr)
                continue
            # keyword=all may be a dud on this tenant — sweep a-z, but only
            # for Active (speculative statuses aren't worth 26 requests each)
            if status != "Active":
                continue
            print(f"  {status} / disciplined={disciplined}: keyword=all "
                  "empty; sweeping a-z", file=sys.stderr)
            for letter in "abcdefghijklmnopqrstuvwxyz":
                try:
                    batch = fetch_keyword(letter, status, disciplined)
                except Exception:
                    batch = []
                fresh = add_records(batch, status, disciplined)
                if batch:
                    print(f"    keyword={letter}: {len(batch)} records "
                          f"({fresh} new, total {len(out)})", file=sys.stderr)
                time.sleep(0.4)
    return out


def probe():
    url = build_url("smith", "Active", "false", 0, 3)
    print(f"Probing {url}\n", file=sys.stderr)
    try:
        data = get(url)
    except Exception as e:
        print(f"Endpoint failed: {e}\n"
              "Re-capture the request URL from the register page (F12 -> "
              "Network -> Fetch/XHR\n-> search on the page) and update "
              "SEARCH/build_url above.", file=sys.stderr)
        return
    batch = extract_batch(data)
    if not batch:
        print("Endpoint answered but returned 0 records for keyword=smith — "
              "the filter\nparameters have likely changed. Re-capture the URL "
              "from the register page\n(F12 -> Network -> Fetch/XHR).",
              file=sys.stderr)
        return
    print("Endpoint is LIVE — sample record:", file=sys.stderr)
    print(json.dumps(batch[0], indent=2)[:1500])


def main():
    if "--probe" in sys.argv:
        probe()
        return
    print("Pulling NV Board licensee register...", file=sys.stderr)
    records = fetch_all()
    print(f"Total unique records: {len(records)}", file=sys.stderr)
    if not records:
        print("No records returned — run with --probe to diagnose.",
              file=sys.stderr)
        return

    with open("nv-board-raw.json", "w") as f:
        json.dump(records, f, indent=2)

    cols = ["DC_LastName", "DC_FirstName", "License_Number", "License_Status",
            "License_Type", "City", "State", "License_Expiry",
            "Disciplinary_Action", "Board_Profile_Id", "Source"]
    with open("nv-board-licensees.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        for rec in records:
            w.writerow({
                "DC_LastName": pick(rec, FIELD_MAP["last"]),
                "DC_FirstName": pick(rec, FIELD_MAP["first"]),
                "License_Number": pick(rec, FIELD_MAP["license"]),
                "License_Status": pick(rec, FIELD_MAP["status"]),
                # the type column is a lookup token; the query filter fixes it
                "License_Type": LICENSE_TYPE,
                "City": pick(rec, FIELD_MAP["city"]),
                "State": "NV",
                "License_Expiry": pick(rec, FIELD_MAP["expiry"]),
                "Disciplinary_Action": pick(rec, FIELD_MAP["disc"]),
                "Board_Profile_Id": pick(rec, FIELD_MAP["id"]),
                "Source": "NV Board (Thentia)",
            })
    print(f"Wrote nv-board-licensees.csv ({len(records)} licensees) and "
          "nv-board-raw.json", file=sys.stderr)
    print("\nNext: python3 merge_lists.py — folds license status into "
          "nv-chiropractor-list.csv", file=sys.stderr)


if __name__ == "__main__":
    main()
