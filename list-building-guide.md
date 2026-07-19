# ELE Practice Analytics — List-Building & Enrichment Guide

The whole go-to-market rests on one asset: a clean, enriched list of every
insurance-billing chiropractor in Nevada (~645 licensed DCs total). This is the
fuel for the outbound kit. Build it once, keep it current, work it forever.

**Files in this folder:**
- `pull_nppes.R` — pulls the raw statewide list from the federal registry
- `pull_nv_board.R` — scrapes the NV Board's public licensee register (Thentia portal)
- `merge_lists.R` — folds Board license status into the master list automatically
- `nv-chiropractor-list.csv` — the working spreadsheet (template + 2 example rows)
- `outbound-kit.md` / `founding-client-offer.md` — what you do with the list
- (`pull_nppes.py` / `pull_nv_board.py` / `merge_lists.py` — identical Python
  versions, if you ever prefer them; the R scripts are the primary path)

One-time R setup: `install.packages(c("httr", "jsonlite"))`

---

## The 3 sources (stack them)

| Source | Gives you | Cost | Use for |
|---|---|---|---|
| **NPPES NPI Registry** (npiregistry.cms.hhs.gov) | Name, practice address, phone, NPI, statewide | Free | The backbone — pull the whole state |
| **NV Board GLSuite licensee search** (nvbochiro.glsuite.us) | Authoritative license status (active/inactive) | Free | Verify each is currently licensed |
| **NV Board mailing labels/list** (chirobd.nv.gov, per NRS 634) | Official name + mailing address list/labels | Small fee | Shortcut for the physical-letter batch |

Then enrich with **clinic websites + Google Maps** for email, and the
insurance-billing signal.

---

## Step 1 — Pull the backbone (NPPES)

NPPES is the free federal provider registry. Taxonomy `111N00000X` = Chiropractor.

**Easiest (no code):** go to https://npiregistry.cms.hhs.gov/search, set
Taxonomy = "Chiropractor", State = NV, run it, and export the results to CSV.

**Repeatable (script):** run `Rscript pull_nppes.R` from this folder. It pages
through the API, tags each record by segment (Clark / Washoe / Other NV), and
writes `nv-chiropractor-list.csv` in the exact column format below. Re-run it
monthly to catch new providers — NPPES updates weekly.

> Note: this pull must run on your own machine. This build environment's network
> policy blocks the CMS domain, so the script couldn't populate the list here.

**What NPPES gives you:** name, practice address, phone, NPI.
**What it doesn't:** email, license status, or whether they bill insurance —
that's Steps 2–4.

## Step 2 — Verify license status (automated)

The Board's current public register lives on a Thentia Cloud portal
(nvcpbn.portalus.thentiacloud.net/webs/portal/register/#/). It's a JavaScript
app, but its data comes from a public JSON API — `pull_nv_board.R` pages
through that API and writes `nv-board-licensees.csv`.

```
Rscript pull_nv_board.R         # scrape the register (--probe to diagnose)
Rscript merge_lists.R           # fold license status into the master list
```

The merge fills `License_Status` on every matched row, tags license numbers in
Notes, and appends Board licensees NPPES missed (DCs without an individual NPI)
as new leads. Drop or deprioritize anything not Active — retired/lapsed DCs are
not targets. If Thentia ever changes its endpoint, `--probe` mode prints
30-second instructions for finding the new one in Chrome's Network tab.

Manual fallback: the older GLSuite search
(nvbochiro.glsuite.us/.../LicenseeSearch.aspx) still answers one-off checks.

## Step 3 — Enrich contact info (the real work)

For each row, spend ~2 minutes filling:
- **Website** — Google "[Clinic Name] [City] chiropractor"
- **Email** — from the clinic site's contact page (front-desk/info@ is fine; the
  DC's direct email is better if listed)
- **LinkedIn_URL** — search the DC's name + "chiropractic" + Nevada

Batch this. Do 20–30 at a time for whichever segment you're about to work. Don't
enrich all 645 before starting — enrich the batch you'll email that week.

## Step 4 — Flag insurance-billing (your buyer filter)

Cash-only practices are **not** your buyer. Set `Bills_Insurance` using signals
from their website/booking page:

- **Yes** → lists accepted plans (Aetna, UHC, Cigna, BCBS, Medicare), says
  "we bill insurance," or is in-network anywhere
- **No** (`Cash_Only_Flag` = Yes) → "cash-based," "membership," "we don't take
  insurance," concierge/wellness-only language
- **Unknown** → can't tell; keep, but lower priority until confirmed

Only insurance-billing practices have denials — they're the only ones your offer
helps. Filtering these out protects your finite list from wasted touches.

## Step 5 — Prioritize (A / B / C)

| Priority | Who | Why |
|---|---|---|
| **A** | Confirmed insurance-billing, Clark or Washoe, multi-provider/larger clinic, email found | Highest denial volume, easiest to reach — work first |
| **B** | Insurance-billing but smaller, or missing email/LinkedIn, or Other-NV | Good targets, need a little more enrichment |
| **C** | Unknown billing status, or likely cash-only | Confirm before spending a touch; skip if cash-only |

Sort A→C and work top-down. Roughly 30 top-value A clinics also get the physical
letter (outbound kit §5).

---

## Column dictionary (`nv-chiropractor-list.csv`)

| Column | Meaning |
|---|---|
| Priority | A / B / C (Step 5) |
| DC_LastName, DC_FirstName | Provider name (personalization) |
| Clinic_Name | Practice name |
| City, County, State | County auto-tagged Clark/Washoe by the script |
| Practice_Address, Postal | For letters + context |
| Phone | From NPPES |
| Email | You enrich (Step 3) |
| Website, LinkedIn_URL | You enrich (Step 3) |
| NPI | Federal provider ID (dedupe key, credibility) |
| License_Status | Active / Inactive / Unknown (Step 2) |
| Bills_Insurance | Yes / No / Unknown (Step 4) |
| Cash_Only_Flag | Yes if cash/membership-only |
| Segment | Clark / Washoe / Other NV |
| Est_Monthly_Claims | Optional guess for sizing the opportunity |
| Source | Where the row came from (NPPES, Board list, referral) |
| Touch1_Date / Touch2_Date / Touch3_Date | Your 3-email sequence dates |
| LinkedIn_Connected | Y once connected |
| Letter_Mailed | Y once physical letter sent |
| Replied | Y / N |
| Review_Sent | Y once free denial review delivered |
| Founding_Client | Y if one of your first 5 |
| Outcome | Won / Lost / Nurturing / No-fit |
| OptOut | Y if they unsubscribed — never contact again |
| Notes | Anything (payers listed, gatekeeper name, best time to call) |

These columns line up with the tracking fields in `outbound-kit.md` §7 and the
`founding-client-offer.md` tracker, so one spreadsheet runs the whole campaign.

---

## Legal & hygiene

- **Public data, legitimate B2B use.** NPPES is public federal data; the Board
  directory is public record by law. Using it to contact practices about a
  business service is fine.
- **CAN-SPAM.** Every email needs a real mailing address + working opt-out. When
  someone opts out, set `OptOut = Y` and never email them again.
- **No implied endorsement.** Never suggest the NV Board or the Nevada
  Chiropractic Association endorses you.
- **De-dupe on NPI**, then on Clinic_Name — several DCs can share one clinic;
  decide whether you target the practice once or each DC.
- **Keep it current.** Re-run `pull_nppes.R` monthly; new providers = new
  first-touch opportunities.

---

## The 3-hour weekend that starts everything

1. Run `Rscript pull_nppes.R` (or export from the NPPES site) → full statewide backbone.
2. Run `Rscript pull_nv_board.R` then `Rscript merge_lists.R` → license-verified list.
3. Filter to Clark + Washoe insurance-billing candidates.
4. Enrich the top **30** (email, website, LinkedIn) → mark them Priority A.
5. Open `outbound-kit.md` and send Monday's first batch.

You now have a finite, named market and a system to work it end to end.
