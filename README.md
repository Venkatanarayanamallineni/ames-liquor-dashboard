# Ames Liquor Dashboard

How has spirits buying in Ames, Iowa changed over 10 years? And do Iowa State students, football weeks, or covid have anything to do with it?

**Tableau dashboard:** (add link after publishing)

## The data
- Iowa Liquor Sales, from data.iowa.gov. Each row is a line on a store's purchase from the state. It is **spirits only** (no beer or wine) and it is **store purchases, not what people drink**.
- 2017 to Oct 2026, about 25.7 million rows, in 40+ part files.
- ISU enrollment by term, college and level (Registrar files, Spring, Summer, Fall 2017 to 2026).
- ISU football schedule, one row per game, 2017 to 2026.

## Run it
1. Put the Iowa liquor CSV files in `data/raw/`.
2. `pip install -r requirements.txt`
3. `py run_etl.py` (Windows) or `python3 run_etl.py`

The script runs `sql/etl.sql`, builds small tables, writes CSVs to `outputs/`, and prints PASS or FAIL checks.
Tableau reads the files in `outputs/`.

## What the ETL does
| Step | What | Why |
|---|---|---|
| 1 | Read every file as text | Old files have blanks and 2 date formats |
| 2 to 3 | Keep Ames stores, remove exact duplicate rows | Keep by `store_no`, because old rows have no city. 2022 and 2025 had a part file that was a full copy |
| 4 | Real types, covid period, clean category names | Dates came as `2017-01-23` and `1/3/2017`. Four category codes were spelled two ways |
| 5 to 8 | Football game windows (game day -3 to +3), joined to sales | Stores order ahead of a game, not on game day |
| 9 to 10 | Small tables, enrollment per term | Tableau stays simple |

Covid periods: before 2020-03-17, until 2023-05-11, after.

## Data quality log
- Mixed date formats across years. Parse both, check for nulls.
- Exact duplicate rows from overlapping part files. Dedupe on full row, not invoice + item. Same item can appear twice on one invoice with different quantities.
- 3,427 rows share an invoice and item but differ in quantity. Checked samples, they are real separate lines. Kept.
- Category names: LIQUEUR vs LIQUEURS, SPIRIT vs SPIRITS SPECIALTY. Same codes. Standardized.
- 305 rows with no category. Labeled UNKNOWN.
- Football file: 8 game windows were the wrong length, one had a year typo (Oregon bowl). Rebuilt around one game date.
- Totals tie to the dollar in every table after every step.

## What I found
- About 617K Ames rows, $98.8M. Purchases happen on Wednesday and Thursday. Almost nothing on weekends.
- Liters peaked in 2021, then fell. Average price per liter rose about 29% from 2017 to 2024, then flattened.
- Active stores grew from 26 (2017) to 43 (2026), but many are small.
- Liters per student (Fall and Spring) peaked in 2020 to 2021 and are back near the 2019 level.
- Spring 2026 liters are down about 9.5% vs Spring 2025. Two stores (Sam's Club, Hy-Vee #1) explain about 70% of the drop.
- Weekdays before ISU games run about 7% to 22% above normal weekdays. Home games were not higher than away games, so this may be the football season and not the game.

## Tested and rejected
- Price vs volume. Overall correlation was weak (-0.27) and it disappeared inside one category (+0.11, American Vodkas). The pattern is mostly category mix, not buyers reacting to price.

## Limits
- Spirits only. No beer, wine, or THC drinks.
- Store purchases are not drinking. No age in the data, so nothing here says anything about Gen Z.
- Ames also has a lot of non-student residents. Summer is left out of the per-student view.
- Month to term mapping is rough (Jan to May Spring, Jun to Jul Summer, Aug to Dec Fall).
- 2026 is a partial year. Charts compare Jan to Oct only.
- `store_no` can change for the same business (Crown Liquor, World Liquor).

## Next
- Pull new months from the Iowa open data API, rerun the ETL on a schedule, refresh the dashboard.

Tableau calculations are in `docs/calcs.md`.
