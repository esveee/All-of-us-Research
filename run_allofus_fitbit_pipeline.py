"""
Run inside an authorized All of Us Researcher Workbench PYTHON notebook.
Usage in Workbench notebook (where SQL file is in the working directory):
  %run run_allofus_fitbit_pipeline.py
Or paste this code in a Workbench notebook cell.

For Workbench 2.0, fill PROJECT and CDR explicitly. Do not export patient data.
"""
from pathlib import Path
from google.cloud import bigquery

# Current official v9 Controlled Tier dataset at writing time.
# Registered tier alternative: wb-affable-acorn-7941.R2025Q4R6
# On Workbench 2.0, manually verify this reference resource is mounted/authorized.
CDR = "wb-silky-artichoke-2408.C2025Q4R6"

# UPDATE THIS to your approved Workbench project (not a public/personal project).
BILLING_PROJECT = "REPLACE_WITH_YOUR_WORKBENCH_PROJECT"
OUTPUT_DATASET = f"{BILLING_PROJECT}.fitbit_mdd_cvd"
BQ_LOCATION = "US"  # Confirm that this matches the source dataset location.

if "REPLACE_WITH" in BILLING_PROJECT:
    raise ValueError("Set BILLING_PROJECT to your authorized All of Us workspace GCP project first.")

sql_path = Path(__file__).with_name("allofus_fitbit_mdd_cvd_pipeline.sql")
sql = sql_path.read_text(encoding="utf-8")
sql = sql.replace("{{CDR}}", CDR).replace("{{OUTPUT_DATASET}}", OUTPUT_DATASET)
if "{{" in sql:
    raise ValueError("Unresolved SQL template placeholder(s).")

client = bigquery.Client(project=BILLING_PROJECT, location=BQ_LOCATION)
# You need permission to create a dataset in your approved project, or precreate it.
ds = bigquery.Dataset(OUTPUT_DATASET)
ds.location = BQ_LOCATION
client.create_dataset(ds, exists_ok=True)
print(f"Running BigQuery pipeline from {CDR} into {OUTPUT_DATASET}")
job = client.query(sql, location=BQ_LOCATION)
# The last SQL statement returns small aggregate diagnostics only.
rows = list(job.result())
for r in rows:
    print(dict(r.items()))
print("Finished. Created 7 tables and two views (sequence_180d, model_features_90d).")
