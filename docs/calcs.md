# Tableau calculations

Every calculated field and filter, and why it exists.

## Price per liter
```
SUM([dollars]) / SUM([liters])
```
Sum first, then divide. Averaging a ratio gives the wrong number when months have different volumes.
It is average price paid per liter. It moves with price and with what people buy (mix).

## In YTD Window
```
MONTH([month_start]) <= MONTH({ MAX([month_start]) })
```
Keeps only Jan up to the latest month in the data, for every year. Put it on Filters, set to True.
Without it, the current partial year looks like a crash next to full years.

## Liters per enrolled student (naming note)
Numerator is ALL Ames purchases (students, locals, staff). Denominator is ISU headcount. Label it "per enrolled student". Never say "bought by students".

## term_type filter (liters per student sheets)
`term_type <> 'Summer'`
Summer is excluded because many non-students live in Ames all year.
Put this filter on that sheet only, not on the data source. Summer stays in the trend views.

## Category share (2025 vs 2026)
`SUM(liters)` with quick table calculation Percent of Total, compute along Table (Down).
Use with In YTD Window = True.

## Headcount on monthly data
Use AVG([headcount]), never SUM. Enrollment is one number per term and repeats on every month of that term.

## Numbers I checked by hand
| What | Value | Date range |
|---|---|---|
| Liters change, 2026 vs 2025 | about -37K | Jan to Oct |
| Price per liter change | +$0.339 | Jan to Oct |

## New tables (step 10b)
- `monthly_index.csv`: rolling 12-month liters, 2019 total = 100. Plot index_2019 by month_start.
- `price_mix.csv`: yearly change in average price per liter = price_effect + mix_effect (adds up exactly). Same Jan to latest month every year.
- `game_lift.csv`: avg liters per sales day by days_from_game, compared with non_game days on the SAME weekday, Sep to Nov only (stores buy Wed/Thu, so plain comparison is a weekday artifact). `game_lift_phase.csv`: same, per phase. Few game days, treat as a hint.

- `dashboard_daily.csv`: one row per sales day with season, covid period, game phase, days from game, liters, dollars, active stores, term headcount. The whole dashboard reads this one file so filters work on every sheet. Headcount repeats per day of a term: use AVG, never SUM. Daily liters are not the same as the sum of monthly headcount.

- `price_tier_mix.csv`: liter share of value / mid / premium rows per year. Tier = price per liter vs the median of the same category and year (below 0.8x value, above 1.25x premium). Same Jan to latest month each year.
- `bottle_size_mix.csv`: liter share by bottle size. A shift to smaller bottles raises price per liter without a price rise.
- `origin_mix.csv`: imported share by category name. Rough: names matching IMPORTED, SCOTCH, IRISH, CANADIAN, TEQUILA, MEZCAL, COGNAC.

- `term_sales.csv`: per Fall and Spring term, headcount and average monthly liters.
- `driver_tests.csv`: correlations (enrollment vs liters, year over year change, stores vs liters). Few points (about 10 per term type), so say 'tracks' or 'does not track', never 'drives'. Correlation is not cause.
- `store_growth.csv`: per year (Jan to latest month) active stores, liters, liters per store, top 3 store share, new stores. 2017 new_stores = everything, ignore it.

- `season_gap.csv`: average monthly liters in school months vs Jun to Jul, per year. summer_vs_school below 1 means purchases dip when students leave. Local residents and staff stay, so it is a hint.

- `store_icons.csv`: one row per active store per year with col and row positions (10 per row). Used for the football pictogram. Not a real store list.
