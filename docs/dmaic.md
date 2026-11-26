# DMAIC: Ames Liquor Data Quality

## Define
- **Problem:** Iowa ships each year in part files, and some parts repeat the same rows. A bad load or join can count rows twice, and the dashboard shows wrong totals without anyone noticing. The source itself can also change: links break, formats change, and category codes get reused.
- **Goal:** Every refresh matches the cleaned source on dollars, liters and row count, with zero silent errors. A bad refresh never reaches Tableau.
- **Scope:** Ames stores only, filtered by store number (old rows have a blank city). Jan 2016 to the latest month Iowa posted (Oct 2026 right now), plus ISU football games and ISU enrollment.

## Measure
**First build (old files, Nov 2026)**
- Raw: 25,728,535 rows across 40+ files
- Exact duplicates: 1,148,819 (4.47% defect rate). 2022 and 2025 each had one full copy file, 2026 had small overlaps
- 3,427 rows had the same invoice and item but different quantities. I checked samples, they are real separate lines, so I kept them
- Football file: 8 wrong window lengths, 1 year typo, some windows overlapped on the same day

**Automated rebuild (Iowa Data Hub files, Nov 2026)**
- Source links broken: the old API (m3tr-qhgy) is gone, the new `rows.csv` link returns 0 bytes, and the `rows.json` zip comes back corrupt. Only the manual download on the website works
- Formats changed between years: 2019 zip has CSV parts, the 2026 API serves JSON lines
- 2016 category re-coding: Iowa shifted category codes by one slot on 2016-08-27. 33 codes have two names, and about 12,500 rows before that date carry codes that mean a different category today (example: 1011400 was Bottled in Bond Bourbon, now Tennessee Whiskies)
- 187 rows in 2016 have a blank category name (kept as UNKNOWN, 0.03%)
- City vs store number filter: for 2019, filtering by city alone missed 54 rows ($3,404) that only the store number filter keeps

## Analyze (5 Whys)
1. Totals would be wrong because rows were counted twice, or labeled with the wrong category.
2. Rows were doubled because part files overlapped. Labels were wrong because codes changed meaning in 2016.
3. The state export comes in parts with copies, and Iowa reused codes without a new column.
4. Nothing caught it because files were stacked and joined with no checks, and the category check trusted the code.
5. The right tests are a full row match for duplicates, and one name per code inside each coding period, with the name as the source of truth.

## Improve
- Dedupe on the full row, not invoice plus item
- Filter by store number to keep the old blank-city rows
- Football: one row per game, nearest game wins on overlapping days
- Category: keep the name as given, check codes per coding period (before and after 2016-08-27)
- Automated pipeline: zips go in a drop folder, n8n runs a prefilter (Ames rows only, newest zip per year, only new or changed zips), then the DuckDB ETL in a Docker container, then the checks
- Prefilter cut 5.5 GB of zips down to 137 MB of Ames rows. A normal month only re-reads the new 2026 zip
- Checks now: 7 that stop the refresh, 1 warning (see Control)
- **After:** 679,287 rows, $106,874,885, 2016-01-05 to 2026-10-30, 61 stores, all checks pass

## Control
- Refresh monthly, after Iowa posts new sales data
- Checks that stop the refresh:
  1. Dollar totals match in all tables
  2. No null sale dates
  3. No rows lost in the typing step
  4. One name per category code, per coding period
  5. No exact duplicate rows left
  6. One game per date (the football join cannot double count)
  7. No year lost more than 1% of its rows vs the last good run
- Warning only: months with no ISU headcount (2016 has none, enrollment data starts in 2017)
- Fail rule: if any check fails, the outputs and `ames_story.xlsx` are not written. Tableau keeps the last good version, and n8n stops with the reason
- New Ames store number found: the prefilter warns, then run one full rebuild (`FULL=1`)

**Runbook**
1. Download the new 2026 zip from data.iowa.gov and replace the old one in `data/`
2. Start Docker, open n8n, click Execute workflow
3. If n8n stops red, read the FAIL line and fix the source. Nothing was published
4. If `ok: true`, open Tableau, Data > Refresh All Extracts
5. Save to Tableau Public, then push the repo
