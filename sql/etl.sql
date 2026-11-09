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

-- STEP 11. Export small CSVs for Tableau.
COPY daily_store        TO 'outputs/daily_store.csv'        (HEADER, DELIMITER ',');
COPY monthly_category   TO 'outputs/monthly_category.csv'   (HEADER, DELIMITER ',');
COPY monthly_students   TO 'outputs/monthly_students.csv'   (HEADER, DELIMITER ',');
COPY liters_per_student TO 'outputs/liters_per_student.csv' (HEADER, DELIMITER ',');
