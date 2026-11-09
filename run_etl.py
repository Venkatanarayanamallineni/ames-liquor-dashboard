"""Run the Ames liquor ETL.

Usage (from this folder):
    pip install -r requirements.txt
    py run_etl.py          (Windows)
    python3 run_etl.py     (Mac or Linux)

Reads  data/raw/*.csv  (Iowa liquor sales files you download)
Runs   sql/etl.sql
Writes outputs/*.csv   (small files for Tableau)
"""
import os
import sys
import time
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parent
SQL_FILE = ROOT / "sql" / "etl.sql"
RAW_DIR = ROOT / "data" / "raw"
DB_FILE = ROOT / "ames.duckdb"


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

    # 4. One category code should have one category name.
    n = con.execute(
        """
        SELECT count(*) FROM (
          SELECT category_code FROM ames_liquor
          WHERE category_code IS NOT NULL AND trim(category_code) <> ''
          GROUP BY 1 HAVING count(DISTINCT category_name) > 1
        )
        """
    ).fetchone()[0]
    results.append(("one name per category code", n == 0, f"{n} codes with 2+ names"))

    # 5. Every month has an enrollment number (a missing one means enrollment file is behind).
    n = con.execute("SELECT count(*) FROM monthly_students WHERE headcount IS NULL").fetchone()[0]
    results.append(("every month has headcount", n == 0, f"{n} months missing headcount"))

    return results


def main():
    files = sorted(RAW_DIR.glob("*.csv"))
    if not files:
        sys.exit(f"No CSV files in {RAW_DIR}. Put the Iowa liquor sales files there first.")
    print(f"Found {len(files)} raw files in {RAW_DIR}")

    os.chdir(ROOT)  # etl.sql uses paths relative to the repo root
    (ROOT / "outputs").mkdir(exist_ok=True)

    con = duckdb.connect(str(DB_FILE))
    statements = con.extract_statements(SQL_FILE.read_text(encoding="utf-8"))
    start = time.time()
    for i, stmt in enumerate(statements, 1):
        first_line = next(
            (ln.strip() for ln in stmt.query.splitlines() if ln.strip() and not ln.strip().startswith("--")),
            "",
        )
        print(f"[{i}/{len(statements)}] {first_line[:70]}")
        con.execute(stmt)
    print(f"ETL finished in {time.time() - start:.0f} seconds\n")

    rows, first, last, stores, dollars = con.execute(
        "SELECT count(*), min(sale_date), max(sale_date), count(DISTINCT store_no), round(sum(sales_dollars)) FROM ames_liquor"
    ).fetchone()
    print(f"Ames rows: {rows:,}  |  {first} to {last}  |  stores: {stores}  |  dollars: {dollars:,.0f}\n")

    all_ok = True
    for name, passed, detail in run_checks(con):
        print(f"{'PASS' if passed else 'FAIL'}  {name}  ({detail})")
        all_ok = all_ok and passed

    con.close()
    print("\nOutputs written to outputs/")
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
