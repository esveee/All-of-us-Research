-- All of Us Fitbit -> EHR event prediction | Google BigQuery Standard SQL
-- Version: 2026-10-10 | Intended for Researcher Workbench, inside an approved workspace.
-- Requires substitution of {{CDR}} and {{OUTPUT_DATASET}} by run_allofus_fitbit_pipeline.py
-- before execution. Do not run the unsubstituted file.
--
-- Creates:
--   1. phenotype_roots      (auditable SNOMED concept seeds)
--   2. phenotype_concepts   (expanded standard SNOMED descendants)
--   3. clinical_events      (first recorded MDD / MI / ischemic stroke / HF / composite CVD)
--   4. fitbit_daily         (SPARSE one row per person/date with at least one Fitbit modality)
--   5. anchor_features      (monthly risk-time anchors plus 30/90/180-day Fitbit features)
--   6. ehr_prior_features  (pre-index EHR utilization / condition burden)
--   7. prediction_landmarks (at-risk records; nullable outcome labels for 30/90/180 days)
--   8. sequence_180d (VIEW: daily sequences with explicit missing days)
--   9. model_features_90d (VIEW: leakage-safe model columns)
--
-- Individual-level data must remain inside the authorized All of Us environment.
-- THIS IS A RESEARCH PHENOTYPE, NOT A VALIDATED CLINICAL PREDICTION MODEL.

DECLARE cutoff_date DATE DEFAULT DATE '2025-01-01';  -- CDR v9 documented cutoff; confirm within your data release
DECLARE max_history_days INT64 DEFAULT 180;
DECLARE anchor_step_days INT64 DEFAULT 30;
DECLARE min_ehr_lookback_days INT64 DEFAULT 365;
DECLARE min_fitbit_recorded_days INT64 DEFAULT 14;  -- all modalities combined within 180 days

-- -----------------------------------------------------------------------------
-- 1. Audit-friendly phenotypes (no speculative numeric concept IDs).
-- Exact SNOMED standard concept roots and descendants are selected at run time.
-- Please review the resulting table and phenotype descendants with clinical experts.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{{OUTPUT_DATASET}}.phenotype_roots` AS
WITH wanted AS (
  SELECT 'MDD' AS outcome_type, 'major depressive disorder' AS concept_name UNION ALL
  SELECT 'MDD', 'major depression' UNION ALL
  SELECT 'MI', 'myocardial infarction' UNION ALL
  SELECT 'ISCHEMIC_STROKE', 'cerebral infarction' UNION ALL
  SELECT 'ISCHEMIC_STROKE', 'ischemic stroke' UNION ALL
  SELECT 'HEART_FAILURE', 'heart failure'
)
SELECT DISTINCT w.outcome_type, c.concept_id AS root_concept_id,
                c.concept_name, c.concept_code
FROM wanted w
JOIN `{{CDR}}.concept` c
  ON LOWER(c.concept_name) = w.concept_name
WHERE c.vocabulary_id = 'SNOMED'
  AND c.standard_concept = 'S'
  AND c.domain_id = 'Condition'
  AND c.invalid_reason IS NULL;

ASSERT (
  SELECT COUNT(DISTINCT outcome_type) FROM `{{OUTPUT_DATASET}}.phenotype_roots`
) = 4 AS 'A required phenotype root is missing; review phenotype_roots and CDR vocabulary before proceeding.';

CREATE OR REPLACE TABLE `{{OUTPUT_DATASET}}.phenotype_concepts` AS
SELECT DISTINCT r.outcome_type,
                d.concept_id AS condition_concept_id,
                d.concept_name AS condition_name,
                d.concept_code AS snomed_code
FROM `{{OUTPUT_DATASET}}.phenotype_roots` r
JOIN `{{CDR}}.concept_ancestor` ca
  ON ca.ancestor_concept_id = r.root_concept_id
JOIN `{{CDR}}.concept` d
  ON d.concept_id = ca.descendant_concept_id
WHERE d.domain_id = 'Condition'
  AND d.standard_concept = 'S'
  AND d.invalid_reason IS NULL;

-- Distinct clinical EVENT dates. This is first *EHR-recorded*, not proven incident onset.
CREATE OR REPLACE TABLE `{{OUTPUT_DATASET}}.clinical_events`
CLUSTER BY person_id, outcome_type AS
WITH first_per_type AS (
  SELECT co.person_id, ph.outcome_type,
         MIN(co.condition_start_date) AS first_event_date,
         COUNT(*) AS matching_condition_records
  FROM `{{CDR}}.condition_occurrence` co
  JOIN `{{OUTPUT_DATASET}}.phenotype_concepts` ph
    ON co.condition_concept_id = ph.condition_concept_id
  WHERE co.condition_start_date IS NOT NULL
    AND co.condition_start_date <= cutoff_date
  GROUP BY 1, 2
)
SELECT * FROM first_per_type
UNION ALL
SELECT person_id, 'CVD_COMPOSITE', MIN(first_event_date), SUM(matching_condition_records)
FROM first_per_type
WHERE outcome_type IN ('MI', 'ISCHEMIC_STROKE', 'HEART_FAILURE')
GROUP BY person_id;

-- -----------------------------------------------------------------------------
-- 2. Fitbit at the DAILY level. No fill-forward and no zero-filling missing days.
-- A sparse daily table is cheaper and better for modeling missingness than a full
-- calendar for every participant over 14 years.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{{OUTPUT_DATASET}}.fitbit_daily`
PARTITION BY day CLUSTER BY person_id AS
WITH activity AS (
  SELECT a.person_id, CAST(a.date AS DATE) AS day,
         MAX(SAFE_CAST(a.steps AS FLOAT64)) AS steps,
         MAX(SAFE_CAST(a.sedentary_minutes AS FLOAT64)) AS sedentary_minutes,
         MAX(SAFE_CAST(a.lightly_active_minutes AS FLOAT64)) AS lightly_active_minutes,
         MAX(SAFE_CAST(a.fairly_active_minutes AS FLOAT64)) AS fairly_active_minutes,
         MAX(SAFE_CAST(a.very_active_minutes AS FLOAT64)) AS very_active_minutes,
         MAX(SAFE_CAST(a.calories_out AS FLOAT64)) AS calories_out
  FROM `{{CDR}}.activity_summary` a
  WHERE CAST(a.date AS DATE) <= cutoff_date
  GROUP BY 1, 2
),
sleep AS (
  -- Main nocturnal sleep only; sleep_date is the date assigned by Fitbit.
  SELECT s.person_id, CAST(s.sleep_date AS DATE) AS day,
         MAX(SAFE_CAST(s.minute_asleep AS FLOAT64)) AS sleep_minutes,
         MAX(SAFE_CAST(s.minute_in_bed AS FLOAT64)) AS sleep_in_bed_minutes,
         MAX(SAFE_CAST(s.minute_awake AS FLOAT64)) AS sleep_awake_minutes,
         MAX(SAFE_CAST(s.minute_deep AS FLOAT64)) AS sleep_deep_minutes,
         MAX(SAFE_CAST(s.minute_light AS FLOAT64)) AS sleep_light_minutes,
         MAX(SAFE_CAST(s.minute_rem AS FLOAT64)) AS sleep_rem_minutes,
         MAX(SAFE_CAST(s.minute_wake AS FLOAT64)) AS sleep_wake_minutes
  FROM `{{CDR}}.sleep_daily_summary` s
  WHERE CAST(s.sleep_date AS DATE) <= cutoff_date
    AND LOWER(CAST(s.is_main_sleep AS STRING)) IN ('true', '1')
  GROUP BY 1, 2
),
-- Normalize one-second and one-minute Fitbit recordings to one observation per
-- MINUTE, so high-frequency recordings do not dominate the daily averages.
hr_minutes AS (
  SELECT h.person_id,
         CAST(h.datetime AS DATE) AS day,
         DATETIME_TRUNC(CAST(h.datetime AS DATETIME), MINUTE) AS minute_ts,
         AVG(SAFE_CAST(h.heart_rate_value AS FLOAT64)) AS bpm
  FROM `{{CDR}}.heart_rate_minute_level` h
  WHERE CAST(h.datetime AS DATE) <= cutoff_date
    AND SAFE_CAST(h.heart_rate_value AS FLOAT64) BETWEEN 35 AND 210
  GROUP BY 1, 2, 3
),
hr_day AS (
  SELECT person_id, day,
         AVG(bpm) AS hr_mean_bpm,
         STDDEV_SAMP(bpm) AS hr_sd_bpm,
         APPROX_QUANTILES(bpm, 100)[OFFSET(10)] AS hr_p10_bpm,
         APPROX_QUANTILES(bpm, 100)[OFFSET(90)] AS hr_p90_bpm,
         COUNT(*) AS hr_minutes_observed
  FROM hr_minutes
  GROUP BY 1, 2
),
all_dates AS (
  SELECT person_id, day FROM activity
  UNION DISTINCT SELECT person_id, day FROM sleep
  UNION DISTINCT SELECT person_id, day FROM hr_day
)
SELECT d.person_id, d.day,
       a.steps, a.sedentary_minutes, a.lightly_active_minutes,
       a.fairly_active_minutes, a.very_active_minutes,
       IF(a.fairly_active_minutes IS NULL OR a.very_active_minutes IS NULL,
          NULL, a.fairly_active_minutes + a.very_active_minutes) AS mvpa_minutes,
       a.calories_out,
       s.sleep_minutes, s.sleep_in_bed_minutes, s.sleep_awake_minutes,
       s.sleep_deep_minutes, s.sleep_light_minutes, s.sleep_rem_minutes,
       s.sleep_wake_minutes,
       SAFE_DIVIDE(s.sleep_minutes, s.sleep_in_bed_minutes) AS sleep_efficiency,
       h.hr_mean_bpm, h.hr_sd_bpm, h.hr_p10_bpm, h.hr_p90_bpm,
       h.hr_minutes_observed,
       -- Heuristic QC; tune and report the thresholds in your paper.
       IF(a.steps BETWEEN 100 AND 99999, 1, 0) AS steps_valid,
       IF(s.sleep_minutes BETWEEN 180 AND 900, 1, 0) AS sleep_valid,
       IF(h.hr_minutes_observed >= 600, 1, 0) AS hr_valid,
       IF(a.person_id IS NOT NULL, 1, 0) AS steps_recorded,
       IF(s.person_id IS NOT NULL, 1, 0) AS sleep_recorded,
       IF(h.person_id IS NOT NULL, 1, 0) AS hr_recorded
FROM all_dates d
JOIN `{{CDR}}.person` p ON p.person_id = d.person_id
LEFT JOIN activity a USING (person_id, day)
LEFT JOIN sleep s USING (person_id, day)
LEFT JOIN hr_day h USING (person_id, day);

-- -----------------------------------------------------------------------------
-- 3. Anchors and rolling features, one row per participant/index date.
-- Anchors are fixed every 30 calendar days beginning after 180d of Fitbit-span.
-- Window is [index_date - 180, index_date - 1] ONLY.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{{OUTPUT_DATASET}}.anchor_features`
PARTITION BY index_date CLUSTER BY person_id AS
WITH bounds AS (
  SELECT person_id, MIN(day) AS first_fitbit_date, MAX(day) AS last_fitbit_date
  FROM `{{OUTPUT_DATASET}}.fitbit_daily`
  GROUP BY 1
),
anchors AS (
  SELECT b.person_id, d AS index_date
  FROM bounds b,
  UNNEST(GENERATE_DATE_ARRAY(
    DATE_ADD(b.first_fitbit_date, INTERVAL max_history_days DAY),
    DATE_ADD(b.last_fitbit_date, INTERVAL 1 DAY),
    INTERVAL anchor_step_days DAY)) d
  WHERE d <= cutoff_date
),
wear_agg AS (
  SELECT an.person_id, an.index_date,
         COUNT(f.day) AS recorded_days_180d,
         COUNTIF(f.steps_valid = 1) AS steps_valid_days_180d,
         COUNTIF(f.sleep_valid = 1) AS sleep_valid_days_180d,
         COUNTIF(f.hr_valid = 1) AS hr_valid_days_180d,
         COUNTIF(f.day >= DATE_SUB(an.index_date, INTERVAL 90 DAY)) AS recorded_days_90d,
         COUNTIF(f.day >= DATE_SUB(an.index_date, INTERVAL 30 DAY)) AS recorded_days_30d,
         AVG(IF(f.steps_valid = 1, f.steps, NULL)) AS steps_mean_180d,
         STDDEV_SAMP(IF(f.steps_valid = 1, f.steps, NULL)) AS steps_sd_180d,
         AVG(IF(f.sleep_valid = 1, f.sleep_minutes, NULL)) AS sleep_mean_180d,
         STDDEV_SAMP(IF(f.sleep_valid = 1, f.sleep_minutes, NULL)) AS sleep_sd_180d,
         AVG(IF(f.hr_valid = 1, f.hr_mean_bpm, NULL)) AS hr_mean_180d,
         AVG(IF(f.hr_valid = 1, f.hr_p10_bpm, NULL)) AS hr_p10_mean_180d,
         AVG(IF(f.day >= DATE_SUB(an.index_date, INTERVAL 30 DAY)
                AND f.steps_valid = 1, f.steps, NULL)) AS steps_mean_30d,
         AVG(IF(f.day >= DATE_SUB(an.index_date, INTERVAL 30 DAY)
                AND f.sleep_valid = 1, f.sleep_minutes, NULL)) AS sleep_mean_30d,
         AVG(IF(f.day >= DATE_SUB(an.index_date, INTERVAL 30 DAY)
                AND f.hr_valid = 1, f.hr_mean_bpm, NULL)) AS hr_mean_30d,
         AVG(IF(f.day >= DATE_SUB(an.index_date, INTERVAL 90 DAY)
                AND f.steps_valid = 1, f.steps, NULL)) AS steps_mean_90d,
         AVG(IF(f.day >= DATE_SUB(an.index_date, INTERVAL 90 DAY)
                AND f.sleep_valid = 1, f.sleep_minutes, NULL)) AS sleep_mean_90d,
         AVG(IF(f.day >= DATE_SUB(an.index_date, INTERVAL 90 DAY)
                AND f.hr_valid = 1, f.hr_mean_bpm, NULL)) AS hr_mean_90d
  FROM anchors an
  LEFT JOIN `{{OUTPUT_DATASET}}.fitbit_daily` f
    ON f.person_id = an.person_id
   AND f.day BETWEEN DATE_SUB(an.index_date, INTERVAL max_history_days DAY)
                 AND DATE_SUB(an.index_date, INTERVAL 1 DAY)
  GROUP BY 1, 2
)
SELECT w.*, p.gender_concept_id, p.race_concept_id, p.ethnicity_concept_id,
       EXTRACT(YEAR FROM w.index_date) - p.year_of_birth AS age_approx_at_index,
       SAFE_DIVIDE(w.recorded_days_180d, 180) AS coverage_any_180d,
       SAFE_DIVIDE(w.steps_valid_days_180d, 180) AS coverage_steps_180d,
       SAFE_DIVIDE(w.sleep_valid_days_180d, 180) AS coverage_sleep_180d,
       SAFE_DIVIDE(w.hr_valid_days_180d, 180) AS coverage_hr_180d
FROM wear_agg w
JOIN `{{CDR}}.person` p USING (person_id)
WHERE w.recorded_days_180d >= min_fitbit_recorded_days
  AND w.recorded_days_90d >= 1
  AND w.recorded_days_30d >= 1
  AND EXTRACT(YEAR FROM w.index_date) - p.year_of_birth >= 18;

-- -----------------------------------------------------------------------------
-- 4. Historical EHR covariates at each anchor. DO NOT use future clinical data.
-- Only count conditions/visits within the 365 days preceding the index date.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{{OUTPUT_DATASET}}.ehr_prior_features`
PARTITION BY index_date CLUSTER BY person_id AS
WITH visits AS (
  SELECT a.person_id, a.index_date,
         COUNT(DISTINCT v.visit_occurrence_id) AS ehr_visits_prior_365d
  FROM `{{OUTPUT_DATASET}}.anchor_features` a
  LEFT JOIN `{{CDR}}.visit_occurrence` v
    ON v.person_id = a.person_id
   AND v.visit_start_date BETWEEN DATE_SUB(a.index_date, INTERVAL 365 DAY)
                              AND DATE_SUB(a.index_date, INTERVAL 1 DAY)
  GROUP BY 1, 2
),
diagnoses AS (
  SELECT a.person_id, a.index_date,
         COUNT(co.condition_occurrence_id) AS ehr_condition_records_prior_365d,
         COUNT(DISTINCT co.condition_concept_id) AS ehr_distinct_condition_concepts_prior_365d
  FROM `{{OUTPUT_DATASET}}.anchor_features` a
  LEFT JOIN `{{CDR}}.condition_occurrence` co
    ON co.person_id = a.person_id
   AND co.condition_start_date BETWEEN DATE_SUB(a.index_date, INTERVAL 365 DAY)
                                   AND DATE_SUB(a.index_date, INTERVAL 1 DAY)
  GROUP BY 1, 2
)
SELECT v.person_id, v.index_date,
       v.ehr_visits_prior_365d,
       d.ehr_condition_records_prior_365d,
       d.ehr_distinct_condition_concepts_prior_365d
FROM visits v JOIN diagnoses d USING (person_id, index_date);

-- -----------------------------------------------------------------------------
-- 5. Join each eligible anchor to EHR follow-up, task and future outcomes.
-- A 0 is emitted ONLY when event-free follow-up for that entire horizon is
-- supported. A NULL means outcome status is unknown / right-censored.
-- Cases are eligible if their event occurs before end of EHR observation;
-- all anchors are at-risk: no prior recorded event of that same outcome.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{{OUTPUT_DATASET}}.prediction_landmarks`
PARTITION BY index_date CLUSTER BY outcome_type, person_id AS
WITH ehr_op AS (
  SELECT person_id, observation_period_start_date AS op_start,
         LEAST(observation_period_end_date, cutoff_date) AS op_end
  FROM `{{CDR}}.observation_period`
  WHERE observation_period_end_date >= observation_period_start_date
),
anchor_op AS (
  SELECT a.*, op.op_start, op.op_end,
         ROW_NUMBER() OVER (PARTITION BY a.person_id, a.index_date
                            ORDER BY op.op_end DESC) AS op_rank
  FROM `{{OUTPUT_DATASET}}.anchor_features` a
  JOIN ehr_op op
    ON op.person_id = a.person_id
   AND op.op_start <= DATE_SUB(a.index_date, INTERVAL min_ehr_lookback_days DAY)
   AND op.op_end >= a.index_date
),
joined AS (
  SELECT ao.* EXCEPT(op_rank), target AS outcome_type, e.first_event_date
  FROM anchor_op ao
  CROSS JOIN UNNEST(['MDD', 'MI', 'ISCHEMIC_STROKE', 'HEART_FAILURE', 'CVD_COMPOSITE']) AS target
  LEFT JOIN `{{OUTPUT_DATASET}}.clinical_events` e
    ON e.person_id = ao.person_id AND e.outcome_type = target
  WHERE ao.op_rank = 1
    AND (e.first_event_date IS NULL OR e.first_event_date > ao.index_date)
),
labelled AS (
  SELECT j.*, eprior.ehr_visits_prior_365d,
         eprior.ehr_condition_records_prior_365d,
         eprior.ehr_distinct_condition_concepts_prior_365d,
         CASE
           WHEN first_event_date > index_date
            AND first_event_date <= DATE_ADD(index_date, INTERVAL 30 DAY)
            AND first_event_date <= op_end THEN 1
           WHEN op_end >= DATE_ADD(index_date, INTERVAL 30 DAY)
            AND (first_event_date IS NULL
                 OR first_event_date > DATE_ADD(index_date, INTERVAL 30 DAY)) THEN 0
           ELSE NULL
         END AS label_30d,
         CASE
           WHEN first_event_date > index_date
            AND first_event_date <= DATE_ADD(index_date, INTERVAL 90 DAY)
            AND first_event_date <= op_end THEN 1
           WHEN op_end >= DATE_ADD(index_date, INTERVAL 90 DAY)
            AND (first_event_date IS NULL
                 OR first_event_date > DATE_ADD(index_date, INTERVAL 90 DAY)) THEN 0
           ELSE NULL
         END AS label_90d,
         CASE
           WHEN first_event_date > index_date
            AND first_event_date <= DATE_ADD(index_date, INTERVAL 180 DAY)
            AND first_event_date <= op_end THEN 1
           WHEN op_end >= DATE_ADD(index_date, INTERVAL 180 DAY)
            AND (first_event_date IS NULL
                 OR first_event_date > DATE_ADD(index_date, INTERVAL 180 DAY)) THEN 0
           ELSE NULL
         END AS label_180d
  FROM joined j
  LEFT JOIN `{{OUTPUT_DATASET}}.ehr_prior_features` eprior
    ON eprior.person_id = j.person_id AND eprior.index_date = j.index_date
)
SELECT * FROM labelled;

-- -----------------------------------------------------------------------------
-- 6. On-demand daily sequences. This is a VIEW to avoid creating an enormous
-- repeated physical table. Every index gets the full 180-day calendar and
-- unavailable Fitbit days have NULL values plus missing_day = 1.
-- Use WHERE outcome_type = 'MDD' AND label_90d IS NOT NULL for that task.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `{{OUTPUT_DATASET}}.sequence_180d` AS
SELECT l.person_id, l.index_date, l.outcome_type,
       l.label_30d, l.label_90d, l.label_180d,
       seq_day AS day, DATE_DIFF(l.index_date, seq_day, DAY) AS days_before_index,
       IF(f.person_id IS NULL, 1, 0) AS missing_day,
       f.* EXCEPT (person_id, day)
FROM `{{OUTPUT_DATASET}}.prediction_landmarks` l
CROSS JOIN UNNEST(GENERATE_DATE_ARRAY(
   DATE_SUB(l.index_date, INTERVAL 180 DAY),
   DATE_SUB(l.index_date, INTERVAL 1 DAY))) AS seq_day
LEFT JOIN `{{OUTPUT_DATASET}}.fitbit_daily` f
  ON f.person_id = l.person_id AND f.day = seq_day;

-- Leakage-safe, model-ready tabular features. Keep person_id only as split key;
-- never use it as a predictor. Future event dates and EHR censoring boundaries
-- are purposely omitted from model columns.
CREATE OR REPLACE VIEW `{{OUTPUT_DATASET}}.model_features_90d` AS
SELECT * EXCEPT(first_event_date, op_start, op_end, label_30d, label_180d)
FROM `{{OUTPUT_DATASET}}.prediction_landmarks`
WHERE label_90d IS NOT NULL;

-- The dataset is assembled. Show only aggregate diagnostics in the notebook.
SELECT 'phenotype_roots' AS check_name, outcome_type, COUNT(*) AS n
  FROM `{{OUTPUT_DATASET}}.phenotype_roots` GROUP BY outcome_type
UNION ALL
SELECT 'phenotype_descendants', outcome_type, COUNT(*)
  FROM `{{OUTPUT_DATASET}}.phenotype_concepts` GROUP BY outcome_type
UNION ALL
SELECT 'participants_with_event', outcome_type, COUNT(DISTINCT person_id)
  FROM `{{OUTPUT_DATASET}}.clinical_events` GROUP BY outcome_type
UNION ALL
SELECT 'eligible_90d_landmarks', outcome_type, COUNT(*)
  FROM `{{OUTPUT_DATASET}}.prediction_landmarks`
  WHERE label_90d IS NOT NULL GROUP BY outcome_type
UNION ALL
SELECT 'positive_90d_landmarks', outcome_type, COUNT(*)
  FROM `{{OUTPUT_DATASET}}.prediction_landmarks`
  WHERE label_90d = 1 GROUP BY outcome_type
ORDER BY check_name, outcome_type;
