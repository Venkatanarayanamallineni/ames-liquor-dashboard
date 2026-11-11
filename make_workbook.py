"""Bundle every CSV in outputs/ into one Excel workbook (one tab per CSV).
Tableau connects once to outputs/ames_story.xlsx and each sheet uses the tab it needs.
Run after run_etl.py:   py make_workbook.py     (needs: pip install openpyxl)
"""
import csv, re, sys
from datetime import date
from pathlib import Path
from openpyxl import Workbook

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "outputs"
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def convert_column(values):
    """Pick one type per column so Tableau reads dates and numbers correctly."""
    vals = [v for v in values if v != ""]
    if vals and all(DATE.match(v) for v in vals):
        return [date.fromisoformat(v) if v else None for v in values]
    try:
        if vals:
            ints = [int(v) for v in vals]
            return [int(v) if v else None for v in values]
    except ValueError:
        pass
    try:
        if vals:
            [float(v) for v in vals]
            return [float(v) if v else None for v in values]
    except ValueError:
        pass
    return [v if v else None for v in values]


def main():
    files = sorted(OUT.glob("*.csv"))
    if not files:
        print("No CSV files in outputs/. Run run_etl.py first.")
        return 1
    wb = Workbook()
    wb.remove(wb.active)
    for f in files:
        with open(f, newline="", encoding="utf-8") as fh:
            rows = list(csv.reader(fh))
        header, body = rows[0], rows[1:]
        cols = [convert_column([r[i] if i < len(r) else "" for r in body]) for i in range(len(header))]
        ws = wb.create_sheet(f.stem[:31])
        ws.append(header)
        for r in range(len(body)):
            ws.append([cols[c][r] for c in range(len(header))])
        for c in range(len(header)):  # date columns display as dates
            if body and isinstance(cols[c][0], date):
                for cell in ws.iter_rows(min_row=2, min_col=c + 1, max_col=c + 1):
                    cell[0].number_format = "yyyy-mm-dd"
        print(f"  {f.stem:<22} {len(body):>8,} rows")
    path = OUT / "ames_story.xlsx"
    wb.save(path)
    print(f"\nSaved {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
