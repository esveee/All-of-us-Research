# All of Us Fitbit × EHR: longitudinal MDD/CVD prediction

**Research-only starter pipeline.** This package provides Google BigQuery Standard SQL for authorized All of Us Researcher Workbench environments. It has **not been run against protected All of Us data** and must be checked against the actual mounted Curated Data Repository (CDR), permissions, billing and phenotype expectations.

## Files

- `allofus_fitbit_mdd_cvd_pipeline.sql`: multi-statement SQL template with `{{CDR}}` and `{{OUTPUT_DATASET}}` placeholders.
- `run_allofus_fitbit_pipeline.py`: example Python runner for a secured All of Us Researcher Workbench Python notebook.
- `allofus_fitbit_example_queries.sql`: aggregate sanity checks and examples.

## Set up and execute

1. Obtain authorized Researcher Workbench access, select a suitable All of Us data collection and confirm approved workspace billing/storage. **Do not run in a personal BigQuery project** or transfer participant-level data outside the Workbench.
2. Upload the `.sql` and `.py` files into your approved Workbench notebook environment.
3. Set `BILLING_PROJECT` in the Python runner to your own Workbench-billed GCP project. Set `CDR` to the mounted and authorized dataset resource. Official v9 CDR references as of October 2026 are:
   - Controlled Tier v9: `wb-silky-artichoke-2408.C2025Q4R6`
   - Registered Tier v9: `wb-affable-acorn-7941.R2025Q4R6`
   These references and relevant data collections may need to be attached to the workspace before use.
4. Ensure you have permission to create the approved `fitbit_mdd_cvd` BigQuery output dataset and that its location is compatible with the CDR.
5. From your Workbench notebook, run `%run run_allofus_fitbit_pipeline.py` (or use a notebook cell with the Python runner content); it renders the SQL and executes the script with BigQuery.
6. Confirm the final printed *aggregated* counts, then run the aggregate sanity checks. Review the `phenotype_roots` and `phenotype_concepts` tables before treating resulting outcomes as valid.

## Output dataset

| Object | Grain | Function |
|---|---|---|
| `phenotype_roots` | target × SNOMED root concept | Auditable starting concept definitions |
| `phenotype_concepts` | target × SNOMED descendant | Expand condition concepts |
| `clinical_events` | person × outcome | First diagnosis recorded in supplied EHR |
| `fitbit_daily` | person × **observed** Fitbit day | Activity, sleep, HR and modality-wise quality masks |
| `anchor_features` | person × index date | Prior 30/90/180 day summary features and coverage |
| `ehr_prior_features` | person × index date | **Pre-index** EHR visit/diagnosis counts |
| `prediction_landmarks` | person × index date × target | Eligibility, outcome date and 30/90/180-day labels |
| `model_features_90d` (view) | person × index date × target | Modeling covariates and 90-day label, with explicit removal of future outcome and censoring boundaries |
| `sequence_180d` (view) | person × index date × target × calendar day | Daily regular-grid sequences, with NULLs and `missing_day` on unsampled days |

## Interpretation of the labels

- `label_90d=1` means the person's **first recorded** diagnosis for that phenotype fell on days 1–90 after the prediction index **and within an EHR observation period**.
- `label_90d=0` means no first diagnosis occurred within that horizon and an EHR observation period extends through its end.
- `label_90d IS NULL` means the follow-up is insufficient to classify the window. **Do not train it as a negative.**
- An index date is excluded from a task if the first recorded event happened on or before that date.
- The same event can label several *earlier* prediction anchors. Count unique positive **participants/events**, not only positive anchor rows.
- Targets: `MDD`, `MI`, `ISCHEMIC_STROKE`, `HEART_FAILURE`, and `CVD_COMPOSITE` (the earliest of MI, ischemic stroke or heart-failure diagnosis).
- **A heart-failure diagnosis is not necessarily an acute cardiovascular event.** The composite is not a validated MACE phenotype.

## Important research limitations

1. **Phenotype review:** The exact-name SNOMED roots and their descendants are an initial code set, **not** a validated MDD, MI, stroke or HF phenotype. Review exclusion/inclusion of remission, historical, recurrent, broad, and ambiguous codes. Consider EHR source codes, encounters, repeat diagnoses and diagnosis-specific validation.
2. **Dates:** The official CDR v9 lists a **2025-01-01 data cutoff** despite its 2026 release. The example uses that documented cutoff; ascertain actual data availability. Registered Tier shifts each person's dates; Controlled Tier has unshifted event dates. Keep Fitbit and EHR from the **same tier** and CDR.
3. **Risk-set definitions:** At-risk means no **previous recorded** condition in a finite EHR history; it does not prove no past disease or that symptoms have not started.
4. **EHR follow-up:** OMOP `observation_period` is a proxy. In All of Us it can contain short and fragmented intervals. Sensitivity analyses should use alternative encounter-based follow-up and require evidence of EHR capture. Treat apparently negative labels carefully.
5. **Calendar date and sleep:** `sleep_date` is as assigned by Fitbit, which can differ from the calendar date on which sleep begins. Confirm clinical/index time alignment.
6. **Wearable preprocessing:** A `steps_valid` day uses 100–99,999 steps, a `sleep_valid` day requires 180–900 minutes of sleep, and an `hr_valid` day needs 600 distinct recorded HR minutes. These are **heuristics**, not proven optimal thresholds. The daily 10th-percentile HR is **not** resting heart rate. The script normalizes second-level and minute-level readings to minute averages first.
7. **Missingness:** `fitbit_daily` is sparse; `sequence_180d` generates the missing calendar dates explicitly. Preserve individual modality masks and do not impute zero for unobserved days.
8. **Leakage:** Split by **person**, never randomly by anchor row. A secondary strict evaluation should also split by index time, with a gap/embargo, and report per-person risk vs. per-anchor metrics. Do not apply scalers, feature selection or imputers before train/validation splits.
9. **Right censoring and selection:** Positives can have shorter available follow-up than negatives if events happen early, inducing selection bias. Consider survival analysis / discrete-time hazards and inverse-probability weighting where justified; compare a fixed full-horizon observation cohort in sensitivity analyses.
10. **Cost:** Minute/second-level Fitbit HR can be very large. The SQL aggregates to participant/minute, then participant/day. Run only on approved BigQuery billing resources and inspect estimated bytes before costly queries. The long-format sequence is a **VIEW** to avoid physically materializing a very large repeat panel.

## Suggested experiments

- **Core paper:** MDD 90-day horizon, 180-day observation window, multivariate Fitbit sequences vs. interpretable elastic-net/logistic baselines, plus EHR-only and combined ablations.
- **History length:** Recompute models using the most recent 30, 90 and 180 days from the sequence view; for longer histories update SQL windows and anchor generation consistently.
- **Adherence:** Stratify by daily modality coverage, missingness patterns, and BYOD/WEAR where data permit. Perform *controlled downsampling only after the train/test split*.
- **CVD extension:** Separate MI, ischemic stroke, and HF results before the composite. Interpret MDD-CVD co-occurrence carefully.
- **Validation:** Report unique people/events, lead-time between index and diagnosis, censoring, AUPRC, AUROC, calibration, subgroup performance, and bootstrap intervals at the participant level.

## Official documentation

- [All of Us Data Dictionaries](https://support.researchallofus.org/hc/en-us/articles/360033200232-Data-Dictionaries)
- [Introduction to Wearables Data](https://support.researchallofus.org/hc/en-us/articles/20281023493908-Introduction-to-Wearables-Data-Collection-and-Transformation)
- [Considerations using Fitbit Data](https://support.researchallofus.org/hc/en-us/articles/9651723386388-Considerations-while-using-Fitbit-Data-in-the-All-of-Us-Research-Program)
- [OHDSI EHR Observation Period Guidance](https://ohdsi.github.io/CommonDataModel/ehrObsPeriods.html)
