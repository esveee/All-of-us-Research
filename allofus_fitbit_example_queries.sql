-- Run after allofus_fitbit_mdd_cvd_pipeline.sql.
-- Replace {{OUTPUT_DATASET}} with the approved BigQuery destination dataset.
-- All examples are aggregate previews except the sequence example.

-- 1) Does the primary MDD 90-day task have enough independent participants?
SELECT outcome_type, COUNT(*) AS anchors,
       COUNT(DISTINCT person_id) AS participants,
       COUNTIF(label_90d = 1) AS positive_anchors,
       COUNT(DISTINCT IF(label_90d = 1, person_id, NULL)) AS positive_people,
       AVG(coverage_any_180d) AS mean_recorded_day_coverage,
       AVG(coverage_hr_180d) AS mean_hr_valid_day_coverage
FROM `{{OUTPUT_DATASET}}.prediction_landmarks`
WHERE label_90d IS NOT NULL
GROUP BY outcome_type ORDER BY outcome_type;

-- 2) Fitbit and EHR patient overlap and date range.
SELECT COUNT(DISTINCT person_id) AS fitbit_people,
       COUNT(*) AS recorded_fitbit_person_days,
       MIN(day) AS first_fitbit_day, MAX(day) AS last_fitbit_day
FROM `{{OUTPUT_DATASET}}.fitbit_daily`;

-- 3) Modality coverage among eligible 90-day MDD anchors.
SELECT
  COUNT(DISTINCT person_id) AS people,
  APPROX_QUANTILES(coverage_steps_180d, 4) AS steps_coverage_quartiles,
  APPROX_QUANTILES(coverage_sleep_180d, 4) AS sleep_coverage_quartiles,
  APPROX_QUANTILES(coverage_hr_180d, 4) AS hr_coverage_quartiles
FROM `{{OUTPUT_DATASET}}.prediction_landmarks`
WHERE outcome_type = 'MDD' AND label_90d IS NOT NULL;

-- 4) Preview one 180-day sequence with missingness. RESTRICT to one selected
-- anchor/participant in your secured workspace notebook rather than materializing
-- the full expanded view. Fill ID and index_date only within the Workbench.
-- SELECT *
-- FROM `{{OUTPUT_DATASET}}.sequence_180d`
-- WHERE outcome_type = 'MDD'
--   AND label_90d IS NOT NULL
--   AND person_id = <PERSON_ID_FROM_AUTHORIZED_WORKBENCH>
--   AND index_date = DATE '2023-01-01'
-- ORDER BY day;

-- 5) For ML, start with *one* row per prediction anchor and fitbit summaries:
-- SELECT * FROM `{{OUTPUT_DATASET}}.model_features_90d`
-- WHERE outcome_type = 'MDD' AND label_90d IS NOT NULL;
-- IMPORTANT: Group by person_id for data splitting, and use NULL labels as censored.
