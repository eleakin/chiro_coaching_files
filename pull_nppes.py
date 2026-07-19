#!/usr/bin/env python3
"""
Pull every Nevada chiropractor from the CMS NPPES NPI Registry into a CSV that
matches the ELE list template. Run this on your own machine (no special access
needed): `python3 pull_nppes.py`. Output: nv-chiropractor-list.csv

NPPES is the free, official federal provider registry. Taxonomy 111N00000X =
Chiropractor. This gets you name, practice address, phone, and NPI for the whole
state. You then enrich (email, website, license status, insurance-billing flag)
per list-building-guide.md.
"""
import urllib.request, json, csv, time, sys

BASE = "https://npiregistry.cms.hhs.gov/api/"
CLARK = {"LAS VEGAS", "HENDERSON", "NORTH LAS VEGAS", "BOULDER CITY", "MESQUITE", "LAUGHLIN"}
WASHOE = {"RENO", "SPARKS", "INCLINE VILLAGE"}

COLS = ["Priority", "DC_LastName", "DC_FirstName", "Clinic_Name", "City", "County",
        "State", "Practice_Address", "Postal", "Phone", "Email", "Website",
        "LinkedIn_URL", "NPI", "License_Status", "Bills_Insurance", "Cash_Only_Flag",
        "Segment", "Est_Monthly_Claims", "Source", "Touch1_Date", "Touch2_Date",
        "Touch3_Date", "LinkedIn_Connected", "Letter_Mailed", "Replied",
        "Review_Sent", "Founding_Client", "Outcome", "OptOut", "Notes"]


def pull():
    rows, skip = [], 0
    while True:
        url = (f"{BASE}?version=2.1&taxonomy_description=Chiropractor"
               f"&state=NV&country_code=US&limit=200&skip={skip}")
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                data = json.load(r)
        except Exception as e:
            print("Network error:", e, file=sys.stderr)
            break
        results = data.get("results", [])
        if not results:
            break
        rows.extend(results)
        skip += 200
        if len(results) < 200 or skip > 4000:  # safety cap
            break
        time.sleep(0.3)
    return rows


def main():
    raw = pull()
    print(f"Pulled {len(raw)} provider records from NPPES", file=sys.stderr)
    with open("nv-chiropractor-list.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLS)
        w.writeheader()
        for it in raw:
            basic = it.get("basic", {})
            addrs = it.get("addresses", [])
            addr = next((a for a in addrs if a.get("address_purpose") == "LOCATION"),
                        addrs[0] if addrs else {})
            city = (addr.get("city", "") or "").upper()
            seg = ("Clark (Vegas/Henderson)" if city in CLARK
                   else "Washoe (Reno/Sparks)" if city in WASHOE else "Other NV")
            cnty = ("Clark" if city in CLARK
                    else "Washoe" if city in WASHOE else "")
            w.writerow({
                "DC_LastName": basic.get("last_name", ""),
                "DC_FirstName": basic.get("first_name", ""),
                "Clinic_Name": basic.get("organization_name", ""),
                "City": addr.get("city", ""),
                "County": cnty,
                "State": addr.get("state", ""),
                "Practice_Address": " ".join(filter(None, [
                    addr.get("address_1", ""), addr.get("address_2", "")])).strip(),
                "Postal": (addr.get("postal_code", "") or "")[:5],
                "Phone": addr.get("telephone_number", ""),
                "NPI": it.get("number", ""),
                "Segment": seg,
                "Source": "NPPES",
                "Notes": "org record" if it.get("enumeration_type") == "NPI-2" else "",
            })
    print("Wrote nv-chiropractor-list.csv", file=sys.stderr)


if __name__ == "__main__":
    main()
