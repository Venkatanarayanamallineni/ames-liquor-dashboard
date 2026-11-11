-- Ames liquor ETL. Run order matters. Run from the repo root with: py run_etl.py
-- Paths are relative to the repo root.

-- STEP 1. Point at every raw liquor file. Read everything as text.
-- Old files have blanks and 2 date formats, so no types yet.
-- A view keeps memory low. Nothing is copied until a step needs it.
CREATE OR REPLACE VIEW raw AS
SELECT * FROM read_csv('data/raw/*.csv', all_varchar=true, union_by_name=true, filename=true);

-- STEP 2. Ames stores: any store_no ever labeled AMES.
CREATE OR REPLACE TABLE ames_stores AS
SELECT DISTINCT store_no
FROM raw
WHERE upper(trim(store_city)) = 'AMES';

-- STEP 3. Keep every row from those stores (old rows have a blank city),
-- and drop exact duplicate rows (some part files are full copies).
-- Compare full rows, not invoice + item: the same item can appear twice
-- on one invoice with different quantities.
CREATE OR REPLACE TABLE ames_raw AS
SELECT DISTINCT * EXCLUDE (filename)
FROM raw
WHERE store_no IN (SELECT store_no FROM ames_stores);

-- STEP 4. Real types, covid period, clean category names.
-- Dates come in 2 formats: 2017-01-23 and 1/3/2017. Try both.
-- Category fix: LIQUEUR vs LIQUEURS and SPIRIT vs SPIRITS SPECIALTY
-- were the same category codes with different spelling.
CREATE OR REPLACE TABLE ames_liquor AS
WITH d AS (
  SELECT *,
    CAST(coalesce(try_strptime(ordered_on, '%Y-%m-%d'),
                  try_strptime(ordered_on, '%m/%d/%Y')) AS DATE) AS sale_date
  FROM ames_raw
)
SELECT
  invoice_id, sale_date, year(sale_date) AS yr,
  store_no, store_name, store_address, store_city,
  category_code,
  CASE WHEN category_name LIKE '%LIQUEUR' THEN category_name || 'S'
       WHEN category_name LIKE '%SPIRIT SPECIALTY'
            THEN replace(category_name, 'SPIRIT SPECIALTY', 'SPIRITS SPECIALTY')
       ELSE coalesce(nullif(trim(category_name), ''), 'UNKNOWN') END AS category_name,
  vendor_name, item_no, im_desc,
  try_cast(pack AS INTEGER) AS pack,
  try_cast(bottle_volume_ml AS INTEGER) AS bottle_volume_ml,
  try_cast(sales_bottles AS DOUBLE) AS sales_bottles,
  try_cast(sales_dollars AS DOUBLE) AS sales_dollars,
  try_cast(sales_liters  AS DOUBLE) AS sales_liters,
  CASE
    WHEN sale_date <  DATE '2020-03-17' THEN 'pre_covid'
    WHEN sale_date <= DATE '2023-05-11' THEN 'covid'
    ELSE 'post_covid'
  END AS covid_period
FROM d;

-- STEP 5. Football games (one row per game).
CREATE OR REPLACE TABLE games AS
SELECT * FROM read_csv('data/reference/football_games_clean.csv');

-- STEP 6. Game windows: game day -3 to +3.
-- 7 rows per game. Cancelled and future games are skipped.
CREATE OR REPLACE TABLE w AS
SELECT g.*, t.days_from_game,
       g.game_date + CAST(t.days_from_game AS INTEGER) AS window_date
FROM games g
CROSS JOIN range(-3, 4) AS t(days_from_game)
WHERE g.game_status = 'Played';

-- STEP 7. Some windows share one day. Keep the nearest game.
-- Tie (3 days each side): the upcoming game wins, because days_from_game -3 sorts first.
CREATE OR REPLACE TABLE game_days AS
WITH ranked AS (
  SELECT *,
    row_number() OVER (
      PARTITION BY window_date
      ORDER BY abs(days_from_game), days_from_game
    ) AS rn
  FROM w
)
SELECT * EXCLUDE (rn) FROM ranked WHERE rn = 1;

-- STEP 8. Join sales to game days. LEFT JOIN keeps every Ames row.
CREATE OR REPLACE TABLE ames_final AS
SELECT a.*,
       g.opponent, g.home_away, g.venue, g.result, g.days_from_game,
       CASE WHEN g.window_date IS NULL THEN 'non_game'
            WHEN g.days_from_game = 0  THEN 'game_day'
            WHEN g.days_from_game < 0  THEN 'pre_game'
            ELSE 'post_game' END AS game_phase
FROM ames_liquor a
LEFT JOIN game_days g ON a.sale_date = g.window_date;

-- STEP 9. Small tables for Tableau.
CREATE OR REPLACE TABLE daily_store AS
SELECT
  sale_date,
  store_no,
  arg_max(store_name, sale_date) AS store_name,
  covid_period, game_phase, opponent, venue, days_from_game,
  sum(sales_bottles)  AS bottles,
  sum(sales_dollars)  AS dollars,
  sum(sales_liters)   AS liters,
  count(*)            AS line_items
FROM ames_final
GROUP BY sale_date, store_no, covid_period, game_phase, opponent, venue, days_from_game;

CREATE OR REPLACE TABLE monthly_category AS
SELECT
  CAST(date_trunc('month', sale_date) AS DATE) AS month_start,
  category_name,
  covid_period,
  sum(sales_liters)  AS liters,
  sum(sales_dollars) AS dollars,
  sum(sales_bottles) AS bottles,
  count(*)           AS line_items
FROM ames_liquor
GROUP BY CAST(date_trunc('month', sale_date) AS DATE), category_name, covid_period;

-- STEP 10. Enrollment and students.
-- liters_per_student = ALL Ames liters / ISU headcount. Buyers include locals and staff.
-- Month to term: Jan-May Spring, Jun-Jul Summer, Aug-Dec Fall (rough).
-- LEFT JOIN so a month with no enrollment row yet is kept, with a blank headcount.
CREATE OR REPLACE TABLE enrollment_detail AS
SELECT * FROM read_csv('data/reference/enrollment_detail.csv');

CREATE OR REPLACE TABLE monthly_students AS
WITH m AS (
  SELECT month_start, sum(liters) AS liters, sum(dollars) AS dollars
  FROM monthly_category
  GROUP BY 1
),
t AS (
  SELECT *, year(month_start) AS term_year,
         CASE WHEN month(month_start) BETWEEN 1 AND 5 THEN 'Spring'
              WHEN month(month_start) IN (6, 7)       THEN 'Summer'
              ELSE 'Fall' END AS term_type
  FROM m
),
e AS (
  SELECT term_year, term_type, sum(headcount) AS headcount
  FROM enrollment_detail
  GROUP BY 1, 2
)
SELECT t.*, e.headcount,
       round(t.liters / e.headcount, 3) AS liters_per_student
FROM t
LEFT JOIN e ON t.term_year = e.term_year AND t.term_type = e.term_type;

CREATE OR REPLACE TABLE liters_per_student AS
WITH liq AS (
  SELECT term_year, term_type,
         sum(liters) AS liters,
         count(DISTINCT month_start) AS months
  FROM monthly_students
  GROUP BY 1, 2
),
enr AS (
  SELECT term_year, term_type, sum(headcount) AS headcount
  FROM enrollment_detail
  GROUP BY 1, 2
)
SELECT l.*, e.headcount,
       round(l.liters / l.months / e.headcount, 3) AS liters_per_student_month
FROM liq l
LEFT JOIN enr e ON l.term_year = e.term_year AND l.term_type = e.term_type;

-- STEP 10b. Smarter views for the dashboard.

-- (1) Rolling 12-month liters, indexed to 2019 = 100.
-- Rolling 12 months removes seasonality. 2019 total is the baseline.
CREATE OR REPLACE TABLE monthly_index AS
WITH m AS (
  SELECT month_start, sum(liters) AS liters, sum(dollars) AS dollars
  FROM monthly_category GROUP BY 1
),
r AS (
  SELECT *,
    sum(liters) OVER w AS liters_12m,
    count(*)    OVER w AS months_in_window
  FROM m
  WINDOW w AS (ORDER BY month_start ROWS BETWEEN 11 PRECEDING AND CURRENT ROW)
),
base AS (SELECT sum(liters) AS b FROM m WHERE year(month_start) = 2019)
SELECT r.month_start, r.liters, r.dollars, r.liters_12m,
       round(100 * r.liters_12m / base.b, 1) AS index_2019
FROM r, base
WHERE r.months_in_window = 12;

-- (2) Price effect vs mix effect on average price per liter, year over year.
-- Same months every year (Jan to latest month) so 2026 is comparable.
-- Price effect = sum(old share * change in category price). Mix effect = sum(change in share * new price).
-- The two add up exactly to the change in average price per liter.
CREATE OR REPLACE TABLE price_mix AS
WITH lim AS (SELECT max(month(month_start)) AS mm FROM monthly_category
             WHERE year(month_start) = (SELECT max(year(month_start)) FROM monthly_category)),
cy AS (
  SELECT year(month_start) AS yr, category_name,
         sum(liters) AS liters, sum(dollars) AS dollars
  FROM monthly_category, lim
  WHERE month(month_start) <= lim.mm
  GROUP BY 1, 2
),
c AS (
  SELECT *, liters / sum(liters) OVER (PARTITION BY yr) AS share,
         dollars / nullif(liters, 0) AS price
  FROM cy
),
j AS (
  SELECT b.yr, b.category_name,
         a.share AS share_old, b.share AS share_new,
         a.price AS price_old, b.price AS price_new
  FROM c b JOIN c a ON a.category_name = b.category_name AND a.yr = b.yr - 1
  WHERE a.price IS NOT NULL AND b.price IS NOT NULL
)
SELECT yr,
       round(sum(share_old * price_old), 3) AS avg_price_old,
       round(sum(share_new * price_new), 3) AS avg_price_new,
       round(sum(share_old * (price_new - price_old)), 3) AS price_effect,
       round(sum((share_new - share_old) * price_new), 3) AS mix_effect
FROM j GROUP BY yr ORDER BY yr;

-- (3) Game-week lift, matched by weekday.
-- Stores buy mostly Wed/Thu. Game -3 and -2 are Wed/Thu, +2 and +3 are Mon/Tue.
-- So each game day is compared with non_game days on the SAME weekday.
-- Only Sep to Nov: summer and winter break are low, and would fake a lift.
-- Per day, not per row, because daily_store has one row per store per day.
CREATE OR REPLACE TABLE game_lift AS
WITH wk AS (
  SELECT *, isodow(sale_date) AS dow FROM daily_store
  WHERE isodow(sale_date) BETWEEN 1 AND 5
    AND month(sale_date) BETWEEN 9 AND 11   -- football season only, so school breaks do not inflate the lift
),
base AS (
  SELECT dow, sum(liters) / count(DISTINCT sale_date) AS base_daily
  FROM wk WHERE game_phase = 'non_game' GROUP BY dow
),
g AS (
  SELECT game_phase, days_from_game, dow,
         sum(liters) AS liters, count(DISTINCT sale_date) AS sales_days
  FROM wk WHERE game_phase <> 'non_game' GROUP BY 1, 2, 3
)
SELECT g.*,
       round(g.liters / g.sales_days) AS avg_daily_liters,
       round(base.base_daily) AS base_daily_same_weekday,
       round(100 * (g.liters / g.sales_days / base.base_daily - 1), 1) AS lift_pct
FROM g JOIN base USING (dow);

-- Same idea per phase: liters in the phase vs what the same weekdays do on non_game days.
CREATE OR REPLACE TABLE game_lift_phase AS
SELECT game_phase,
       sum(sales_days) AS sales_days,
       round(100 * (sum(liters) / sum(sales_days * base_daily_same_weekday) - 1), 1) AS lift_pct
FROM game_lift GROUP BY game_phase;

-- STEP 10c. One combined daily table for the dashboard.
-- Every sheet reads this one file, so filters and actions work across all sheets.
-- One row per sales day. Headcount is the term headcount (same on every day of the term).
CREATE OR REPLACE TABLE dashboard_daily AS
WITH day AS (
  SELECT sale_date, covid_period, game_phase, days_from_game, opponent,
         sum(liters)  AS liters,
         sum(dollars) AS dollars,
         sum(line_items) AS line_items,
         count(DISTINCT store_no) AS active_stores
  FROM daily_store
  GROUP BY sale_date, covid_period, game_phase, days_from_game, opponent
)
SELECT d.sale_date,
       year(d.sale_date) AS yr,
       CAST(date_trunc('month', d.sale_date) AS DATE) AS month_start,
       CASE WHEN month(d.sale_date) BETWEEN 1 AND 5 THEN 'Spring'
            WHEN month(d.sale_date) IN (6, 7)       THEN 'Summer'
            ELSE 'Fall' END AS season,
       d.covid_period, d.game_phase, d.days_from_game, d.opponent,
       CASE WHEN d.game_phase = 'game_day' THEN 'Game day'
            WHEN d.game_phase = 'non_game' THEN 'Non-game day'
            ELSE 'Game week' END AS day_type,
       isodow(d.sale_date) AS dow,
       d.liters, d.dollars, d.line_items, d.active_stores,
       m.headcount
FROM day d
LEFT JOIN monthly_students m
  ON m.month_start = CAST(date_trunc('month', d.sale_date) AS DATE);

-- STEP 10d. Did buyers trade up? Three tests. All use the same months every year (Jan to latest month).
-- Returns (negative rows) are left out: only rows with liters > 0 and dollars > 0.

-- (a) Value / mid / premium inside each category and year.
-- Tier compares a row's price per liter with the median of its own category and year,
-- so inflation and category differences do not fake a shift.
CREATE OR REPLACE TABLE price_tier_mix AS
WITH lim AS (SELECT max(month(month_start)) AS mm FROM monthly_category
             WHERE year(month_start) = (SELECT max(year(month_start)) FROM monthly_category)),
r AS (
  SELECT yr, category_name, sales_liters AS liters, sales_dollars AS dollars,
         sales_dollars / sales_liters AS ppl
  FROM ames_liquor, lim
  WHERE sales_liters > 0 AND sales_dollars > 0 AND month(sale_date) <= lim.mm
),
m AS (
  SELECT *, median(ppl) OVER (PARTITION BY yr, category_name) AS med FROM r
),
t AS (
  SELECT yr, liters, dollars,
         CASE WHEN ppl < 0.8 * med THEN '1 value'
              WHEN ppl > 1.25 * med THEN '3 premium'
              ELSE '2 mid' END AS tier
  FROM m
)
SELECT yr, tier,
       round(sum(liters)) AS liters,
       round(sum(liters) / sum(sum(liters)) OVER (PARTITION BY yr), 4) AS liter_share,
       round(sum(dollars) / sum(liters), 3) AS price_per_liter
FROM t GROUP BY yr, tier ORDER BY yr, tier;

-- (b) Bottle size mix. Smaller bottles raise price per liter without any price rise.
CREATE OR REPLACE TABLE bottle_size_mix AS
WITH lim AS (SELECT max(month(month_start)) AS mm FROM monthly_category
             WHERE year(month_start) = (SELECT max(year(month_start)) FROM monthly_category)),
r AS (
  SELECT yr, sales_liters AS liters, sales_dollars AS dollars,
         CASE WHEN bottle_volume_ml <= 375 THEN '1 mini (375 ml or less)'
              WHEN bottle_volume_ml <= 750 THEN '2 750 ml'
              WHEN bottle_volume_ml <= 1000 THEN '3 1 L'
              ELSE '4 1.75 L and up' END AS bottle_size
  FROM ames_liquor, lim
  WHERE sales_liters > 0 AND sales_dollars > 0 AND bottle_volume_ml IS NOT NULL
    AND month(sale_date) <= lim.mm
)
SELECT yr, bottle_size,
       round(sum(liters)) AS liters,
       round(sum(liters) / sum(sum(liters)) OVER (PARTITION BY yr), 4) AS liter_share,
       round(sum(dollars) / sum(liters), 3) AS price_per_liter
FROM r GROUP BY yr, bottle_size ORDER BY yr, bottle_size;

-- (c) Imported by category name (rough: IMPORTED, SCOTCH, IRISH, CANADIAN, TEQUILA, MEZCAL, COGNAC).
CREATE OR REPLACE TABLE origin_mix AS
WITH lim AS (SELECT max(month(month_start)) AS mm FROM monthly_category
             WHERE year(month_start) = (SELECT max(year(month_start)) FROM monthly_category)),
r AS (
  SELECT yr, sales_liters AS liters, sales_dollars AS dollars,
         CASE WHEN regexp_matches(category_name, 'IMPORTED|SCOTCH|IRISH|CANADIAN|TEQUILA|MEZCAL|COGNAC')
              THEN 'Imported (by category name)' ELSE 'Other' END AS origin
  FROM ames_liquor, lim
  WHERE sales_liters > 0 AND sales_dollars > 0 AND month(sale_date) <= lim.mm
)
SELECT yr, origin,
       round(sum(liters)) AS liters,
       round(sum(liters) / sum(sum(liters)) OVER (PARTITION BY yr), 4) AS liter_share,
       round(sum(dollars) / sum(liters), 3) AS price_per_liter
FROM r GROUP BY yr, origin ORDER BY yr, origin;

-- STEP 10e. Driver tests. Do students, stores, or price move spirits volume?
-- Fall and Spring only (summer excluded). Fall 2026 is Aug to Oct only, so it is an average per month.
CREATE OR REPLACE TABLE term_sales AS
SELECT term_year, term_type,
       any_value(headcount)  AS headcount,
       round(avg(liters))    AS avg_monthly_liters,
       count(*)              AS months
FROM monthly_students
WHERE term_type <> 'Summer' AND headcount IS NOT NULL
GROUP BY term_year, term_type
ORDER BY term_year, term_type;

CREATE OR REPLACE TABLE driver_tests AS
WITH yoy AS (
  SELECT a.term_type, a.term_year,
         a.headcount / b.headcount - 1 AS enroll_chg,
         a.avg_monthly_liters / b.avg_monthly_liters - 1 AS liters_chg
  FROM term_sales a JOIN term_sales b
    ON a.term_type = b.term_type AND a.term_year = b.term_year + 1
),
ms AS (
  SELECT month_start, count(DISTINCT store_no) AS stores, sum(liters) AS liters
  FROM daily_store, LATERAL (SELECT CAST(date_trunc('month', sale_date) AS DATE) AS month_start)
  GROUP BY 1
)
SELECT 'Enrollment vs monthly liters, Fall terms' AS test,
       round(corr(headcount, avg_monthly_liters), 2) AS correlation, count(*) AS n
FROM term_sales WHERE term_type = 'Fall'
UNION ALL
SELECT 'Enrollment vs monthly liters, Spring terms',
       round(corr(headcount, avg_monthly_liters), 2), count(*)
FROM term_sales WHERE term_type = 'Spring'
UNION ALL
SELECT 'Year over year: enrollment change vs liters change (Fall and Spring)',
       round(corr(enroll_chg, liters_chg), 2), count(*) FROM yoy
UNION ALL
SELECT 'Year over year, covid-touching pairs removed (2020 to 2022)',
       round(corr(enroll_chg, liters_chg), 2), count(*) FROM yoy WHERE term_year NOT IN (2020, 2021, 2022)
UNION ALL
SELECT 'Active stores vs monthly liters (all months)',
       round(corr(stores, liters), 2), count(*) FROM ms;

-- Summer (Jun, Jul) vs school months. Do purchases drop when students leave?
-- Fall 2026 is Aug to Oct only, so 2026 academic average mixes Jan to May and Aug to Oct.
CREATE OR REPLACE TABLE season_gap AS
SELECT term_year,
       round(avg(CASE WHEN term_type <> 'Summer' THEN liters END)) AS school_months_avg_liters,
       round(avg(CASE WHEN term_type =  'Summer' THEN liters END)) AS summer_months_avg_liters,
       round(avg(CASE WHEN term_type =  'Summer' THEN liters END)
           / avg(CASE WHEN term_type <> 'Summer' THEN liters END), 3) AS summer_vs_school
FROM monthly_students
GROUP BY term_year ORDER BY term_year;

-- Stores: more stores, same bottles? Same months every year (Jan to latest month).
-- new_stores counts a store_no seen for the first time. A store that changed its store_no counts as new.
CREATE OR REPLACE TABLE store_growth AS
WITH lim AS (SELECT max(month(month_start)) AS mm FROM monthly_category
             WHERE year(month_start) = (SELECT max(year(month_start)) FROM monthly_category)),
s AS (
  SELECT yr, store_no, sum(sales_liters) AS liters
  FROM ames_liquor, lim
  WHERE month(sale_date) <= lim.mm
  GROUP BY yr, store_no
),
r AS (SELECT *, row_number() OVER (PARTITION BY yr ORDER BY liters DESC) AS rk FROM s),
f AS (SELECT store_no, min(yr) AS first_yr FROM ames_liquor GROUP BY 1)
SELECT r.yr,
       count(*)                                        AS active_stores,
       round(sum(liters))                              AS liters,
       round(sum(liters) / count(*))                   AS liters_per_store,
       round(sum(CASE WHEN rk <= 3 THEN liters END) / sum(liters), 4) AS top3_share,
       count(*) FILTER (WHERE f.first_yr = r.yr)       AS new_stores
FROM r JOIN f USING (store_no)
GROUP BY r.yr ORDER BY r.yr;

-- One row per store per year, for a football pictogram (10 icons per row).
CREATE OR REPLACE TABLE store_icons AS
SELECT yr, n, (n - 1) % 10 AS col, (n - 1) // 10 AS row
FROM store_growth, range(1, CAST(active_stores AS INTEGER) + 1) AS t(n)
ORDER BY yr, n;

-- STEP 10f. Game by game and by opponent.
-- Extra liters in each game window (Mon to Fri, Sep to Nov) vs normal days on the same weekday.
-- Windows cut off by the end of the data have fewer days: see days_counted.
CREATE OR REPLACE TABLE game_weeks AS
WITH daily AS (
  SELECT sale_date, sum(sales_liters) AS liters FROM ames_liquor GROUP BY 1
),
base AS (
  SELECT isodow(sale_date) AS dow, avg(liters) AS base_daily
  FROM daily
  WHERE month(sale_date) BETWEEN 9 AND 11
    AND sale_date NOT IN (SELECT window_date FROM game_days)
    AND isodow(sale_date) BETWEEN 1 AND 5
  GROUP BY 1
),
gw AS (
  SELECT g.game_date, g.opponent, g.home_away, g.result, g.window_date, g.days_from_game,
         isodow(g.window_date) AS dow, d.liters
  FROM game_days g
  JOIN daily d ON d.sale_date = g.window_date
  WHERE isodow(g.window_date) BETWEEN 1 AND 5 AND month(g.window_date) BETWEEN 9 AND 11
)
SELECT gw.game_date, year(gw.game_date) AS season, gw.opponent, gw.home_away, gw.result,
       count(*)                                  AS days_counted,
       round(sum(gw.liters))                     AS window_liters,
       round(sum(gw.liters - b.base_daily))      AS extra_liters
FROM gw JOIN base b USING (dow)
GROUP BY gw.game_date, gw.opponent, gw.home_away, gw.result
ORDER BY gw.game_date;

CREATE OR REPLACE TABLE opponent_lift AS
SELECT opponent,
       count(*)                          AS games,
       count(*) FILTER (WHERE home_away = 'Home') AS home_games,
       round(sum(extra_liters))          AS total_extra_liters,
       round(avg(extra_liters))          AS avg_extra_liters_per_game
FROM game_weeks
WHERE days_counted >= 3
GROUP BY opponent
ORDER BY total_extra_liters DESC;

-- STEP 11. Export small CSVs for Tableau.
COPY daily_store        TO 'outputs/daily_store.csv'        (HEADER, DELIMITER ',');
COPY monthly_category   TO 'outputs/monthly_category.csv'   (HEADER, DELIMITER ',');
COPY monthly_students   TO 'outputs/monthly_students.csv'   (HEADER, DELIMITER ',');
COPY liters_per_student TO 'outputs/liters_per_student.csv' (HEADER, DELIMITER ',');
COPY monthly_index TO 'outputs/monthly_index.csv' (HEADER, DELIMITER ',');
COPY price_mix     TO 'outputs/price_mix.csv'     (HEADER, DELIMITER ',');
COPY game_lift     TO 'outputs/game_lift.csv'     (HEADER, DELIMITER ',');
COPY game_lift_phase TO 'outputs/game_lift_phase.csv' (HEADER, DELIMITER ',');
COPY dashboard_daily TO 'outputs/dashboard_daily.csv' (HEADER, DELIMITER ',');
COPY price_tier_mix  TO 'outputs/price_tier_mix.csv'  (HEADER, DELIMITER ',');
COPY bottle_size_mix TO 'outputs/bottle_size_mix.csv' (HEADER, DELIMITER ',');
COPY origin_mix      TO 'outputs/origin_mix.csv'      (HEADER, DELIMITER ',');
COPY term_sales   TO 'outputs/term_sales.csv'   (HEADER, DELIMITER ',');
COPY driver_tests TO 'outputs/driver_tests.csv' (HEADER, DELIMITER ',');
COPY store_growth TO 'outputs/store_growth.csv' (HEADER, DELIMITER ',');
COPY season_gap TO 'outputs/season_gap.csv' (HEADER, DELIMITER ',');
COPY store_icons TO 'outputs/store_icons.csv' (HEADER, DELIMITER ',');
COPY game_weeks   TO 'outputs/game_weeks.csv'   (HEADER, DELIMITER ',');
COPY opponent_lift TO 'outputs/opponent_lift.csv' (HEADER, DELIMITER ',');
