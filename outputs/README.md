# Outputs

`py run_etl.py` writes small CSVs here. Tableau reads these files.

| File | One row is | Used for |
|---|---|---|
| monthly_category.csv | month x category | trend, price per liter, category mix, covid colors |
| monthly_students.csv | month | liters vs ISU enrollment |
| liters_per_student.csv | term (Spring, Summer, Fall) | liters per student, Fall and Spring only |
| daily_store.csv | day x store | football game window view |
