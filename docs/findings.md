# Findings

Ames, Iowa. Iowa Liquor Sales (store purchases of spirits), Jan 2017 to Oct 2026. Year comparisons use Jan to Oct in every year.
All numbers come from the ETL outputs. Verdicts say what the data shows, not why.

## The story in one line
Ames spirits volume peaked in 2021 and is now below 2018. Buyers traded down and bought smaller bottles, prices rose about 30%, and more stores split the same bottles.

## Findings
| # | Finding | Numbers | Source file |
|---|---|---|---|
| 1 | Volume peaked in 2021, now lower than 2017 | Jan to Oct liters 475.8K (2017), 566.3K (2021), 417.6K (2026). -12% vs 2017, -26% vs peak. Jan to Oct 2026 is -8.1% vs 2025 | store_growth, monthly_index |
| 2 | Price per liter rose about 30% | $14.43 (2017) to $18.75 (2026). About 84% same-category price rise, about 16% category mix (2018 to 2024) | price_mix |
| 3 | Buyers traded down | Value tier share 44.3% to 52.1%. Premium 16.4% to 14.1% (peak 19.3% in 2020). Premium price per liter +58%, value +29% | price_tier_mix |
| 4 | Smaller bottles | Minis (375 ml or less) 3.6% to 6.5% of liters. Size mix adds about $0.92 of the $4.19 rise (about 22%) | bottle_size_mix |
| 5 | No shift to imported | 26.4% to 26.9% of liters (rough, by category name) | origin_mix |
| 6 | More stores, same bottles | Active stores 26 to 43 (+65%). Liters per store 18.3K to 9.7K (-47%). Top 3 stores 54% to 47.5% | store_growth |
| 7 | Students set the rhythm, not the trend | Jun to Jul purchases 13% to 27% below school months every year (avg about 22%). Enrollment vs monthly liters: Fall -0.02, Spring +0.04 | season_gap, driver_tests |
| 8 | Football is a nudge | About +14% on the Wed and Thu before a game, about 204K extra liters over the seasons (about 2K per game week). Game day itself: nothing visible | game_lift |

## Tested and rejected
- Price vs volume: overall r = -0.27, inside one category r = +0.11 (American Vodkas). Not claimed.
- Stores vs monthly liters: r = -0.10. No link.
- Enrollment year over year vs liters: r = -0.43 without covid-touching years. Opposite sign, small sample (12). Not claimed as cause.
- Post-game "lift" of +72%: tiny Mon/Tue baseline. Not shown as a finding.
- First game lift (+153% on day -3): weekday artifact (Wed vs all weekdays). Fixed by matching the same weekday.

## What is not explained
The 2021 peak and the slide since. Not tested: a long-run drop in spirits drinking, cocktails and ready-to-drink substitution, other products.

## Limits
- Store purchases by all Ames buyers (students, locals, staff). Not student drinking. Spirits only. No age in the data.
- Correlations use few points (10 to 18). Correlation is not cause.
- Tiers compare each row with its category median in that year. A wider price spread can move shares without people trading down.
- "Imported" is by category name. New store counts can include a renamed store (same business, new store number).
- Most fall weeks have a game, so "normal" fall weekdays are few.
