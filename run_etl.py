"""Run the Ames liquor ETL.

Usage (from this folder):
    pip install -r requirements.txt
    py run_etl.py          (Windows)
    python3 run_etl.py     (Mac or Linux)

Reads  data/raw/*.csv and data/raw/*.json  (Iowa liquor sales files)
Runs   sql/etl.sql
Writes outputs/*.csv   (small files for Tableau)
Exit 0 = all checks passed, 1 = a check failed (n8n stops the refresh).
"""
import os
import sys
import time
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parent
SQL_FILE = ROOT / "sql" / "etl.sql"
# Raw folder: set RAW_DIR to override (Docker uses /data/raw). Default is the repo's data/raw.
RAW_DIR = Path(os.environ.get("RAW_DIR", ROOT / "data" / "raw"))
DB_FILE = ROOT / "ames.duckdb"

# Iowa re-coded liquor categories here: old names last seen 2016-08-26, new names from 2016-08-29.
RECODE_DATE = "2016-08-27"

# Columns of the Iowa Data Hub files. JSON is read as text, same as CSV.
COLS = [
    "invoice_id", "ordered_on", "store_no", "store_name", "store_address", "store_city",
    "store_zip_code", "county_fips_code", "county_name", "category_code", "category_name",
    "vendor_number", "vendor_name", "item_no", "im_desc", "pack", "bottle_volume_ml",
    "state_bottle_cost", "state_bottle_retail", "sales_bottles", "sales_dollars",
    "sales_liters", "sales_gallons",
]


def build_raw_view(con, has_csv, has_json):
    """STEP 1. One view over every raw file, CSV and JSON, all columns as text."""
    raw = RAW_DIR.resolve().as_posix()
    parts = []
    if has_csv:
        parts.append(
            f"SELECT * FROM read_csv('{raw}/*.csv', all_varchar=true, "
            "union_by_name=true, filename=true)"
        )
    if has_json:
        cols = ", ".join(f"'{c}': 'VARCHAR'" for c in COLS)
        parts.append(
            f"SELECT * FROM read_json('{raw}/*.json', format='newline_delimited', "
            f"columns={{{cols}}}, filename=true)"
        )
    con.execute("CREATE OR REPLACE VIEW raw AS " + " UNION ALL BY NAME ".join(parts))


def run_checks(con):
    """Return a list of (name, passed, detail)."""
    results = []

    # 1. Dollars must match in every table built from ames_liquor.
    totals = {}
    for table, col in [
        ("ames_liquor", "sales_dollars"),
        ("daily_store", "dollars"),
        ("monthly_category", "dollars"),
        ("monthly_students", "dollars"),
    ]:
        totals[table] = con.execute(f"SELECT round(sum({col}), 2) FROM {table}").fetchone()[0]
    base = totals["ames_liquor"]
    same = all(abs(v - base) < 0.01 for v in totals.values())
    results.append(("dollar totals match in all tables", same, totals))

    # 2. No missing dates.
    n = con.execute("SELECT count(*) FROM ames_liquor WHERE sale_date IS NULL").fetchone()[0]
    results.append(("no null sale_date", n == 0, f"{n} null dates"))

    # 3. Every row from ames_raw made it into ames_liquor.
    a = con.execute("SELECT count(*) FROM ames_raw").fetchone()[0]
    b = con.execute("SELECT count(*) FROM ames_liquor").fetchone()[0]
    results.append(("no rows lost in typing step", a == b, f"{a} vs {b}"))

    # 4. One category code should have one category name, inside each coding period.
    #    Iowa re-coded categories in late Aug 2016 (codes shifted by one slot), so a code
    #    means something else before RECODE_DATE. The name is the source of truth.
    #    UNKNOWN (blank names, 2016 only) is ignored here.
    n = con.execute(
        f"""
        SELECT count(*) FROM (
          SELECT category_code, sale_date >= DATE '{RECODE_DATE}' AS new_codes
          FROM ames_liquor
          WHERE category_code IS NOT NULL AND trim(category_code) <> ''
            AND category_name <> 'UNKNOWN'
          GROUP BY 1, 2 HAVING count(DISTINCT category_name) > 1
        )
        """
    ).fetchone()[0]
    results.append(("one name per category code (per coding period)", n == 0, f"{n} codes with 2+ names"))

    # 5. Missing headcount = warning only. Update enrollment by hand.
    n = con.execute("SELECT count(*) FROM monthly_students WHERE headcount IS NULL").fetchone()[0]
    print(f"{'WARN' if n else 'OK  '}  months missing headcount: {n}")

    # 6. No year lost rows vs the last good run (more than 1% drop = fail).
    con.execute(
        "CREATE OR REPLACE TEMP TABLE year_now AS "
        "SELECT yr, count(*) AS n FROM ames_liquor GROUP BY yr ORDER BY yr"
    )
    now = dict(con.execute("SELECT yr, n FROM year_now").fetchall())
    prev_file = ROOT / "outputs" / "year_counts.csv"
    bad = []
    if prev_file.exists():
        for line in prev_file.read_text().splitlines()[1:]:
            y, c = map(int, line.split(","))
            if now.get(y, 0) < c * 0.99:
                bad.append(f"{y}: {now.get(y, 0)} vs {c}")
    results.append(("no year lost rows vs last run", not bad, bad or "ok"))

    return results


def main():
    csvs = sorted(RAW_DIR.glob("*.csv"))
    jsons = sorted(RAW_DIR.glob("*.json"))
    if not csvs and not jsons:
        sys.exit(f"No CSV or JSON files in {RAW_DIR}. Put the Iowa liquor sales files there first.")
    print(f"Found {len(csvs)} csv and {len(jsons)} json files in {RAW_DIR}")

    os.chdir(ROOT)  # etl.sql uses paths relative to the repo root
    (ROOT / "outputs").mkdir(exist_ok=True)

    con = duckdb.connect(str(DB_FILE))
    build_raw_view(con, bool(csvs), bool(jsons))

    statements = con.extract_statements(SQL_FILE.read_text(encoding="utf-8"))
    start = time.time()
    exports = []  # COPY ... TO outputs/ runs only after all checks pass
    for i, stmt in enumerate(statements, 1):
        first_line = next(
            (ln.strip() for ln in stmt.query.splitlines() if ln.strip() and not ln.strip().startswith("--")),
            "",
        )
        if first_line.upper().startswith("COPY"):
            exports.append(stmt)
            continue
        print(f"[{i}/{len(statements)}] {first_line[:70]}")
        con.execute(stmt)
    print(f"ETL finished in {time.time() - start:.0f} seconds\n")

    rows, first, last, stores, dollars = con.execute(
        "SELECT count(*), min(sale_date), max(sale_date), count(DISTINCT store_no), "
        "round(sum(sales_dollars)) FROM ames_liquor"
    ).fetchone()
    print(f"Ames rows: {rows:,}  |  {first} to {last}  |  stores: {stores}  |  dollars: {dollars:,.0f}\n")

    all_ok = True
    for name, passed, detail in run_checks(con):
        print(f"{'PASS' if passed else 'FAIL'}  {name}  ({detail})")
        all_ok = all_ok and passed

    # Write outputs and year counts only after a good run.
    # A failed run leaves the last good outputs untouched.
    if all_ok:
        for stmt in exports:
            con.execute(stmt)
        con.execute("COPY year_now TO 'outputs/year_counts.csv' (HEADER)")
        print(f"\n{len(exports)} outputs written to outputs/")
    else:
        print("\nChecks failed: outputs NOT updated (last good version kept)")

    con.close()
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()