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
