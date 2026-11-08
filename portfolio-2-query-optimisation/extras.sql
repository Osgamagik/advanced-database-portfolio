-- =====================================================================
-- Portfolio 2 – further optimisation experiments (run AFTER indexes.sql)
-- psql -d carepoint -f extras.sql > evidence/extras_output.txt
-- =====================================================================
SET search_path TO clinic;
SET max_parallel_workers_per_gather = 0;
\timing on

\echo '=== E1. Sargability: wrapping the column in a function defeats the index ==='
\echo '--- E1a. NON-sargable: scheduled_start::date = ... (cast is applied to every row)'
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT count(*) FROM appointment WHERE doctor_id = 17 AND (scheduled_start AT TIME ZONE 'UTC')::date = DATE '2026-11-03';
\echo '--- E1b. Sargable rewrite: half-open timestamp range'
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT count(*) FROM appointment WHERE doctor_id = 17
  AND scheduled_start >= TIMESTAMPTZ '2026-11-03' AND scheduled_start < TIMESTAMPTZ '2026-11-04';

\echo '=== E2. Selectivity: the optimiser ignores an index when most rows match ==='
SELECT status, count(*), round(100.0*count(*)/sum(count(*)) OVER (),1) AS pct FROM appointment GROUP BY status ORDER BY 2 DESC;
CREATE INDEX IF NOT EXISTS ix_tmp_status ON appointment(status);
ANALYZE appointment;
-- max(reason) forces a visit to the table (heap), so an index-only scan is not possible
\echo '--- E2a. status = COMPLETED (~77% of rows) -> expect Seq Scan'
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON) SELECT max(reason) FROM appointment WHERE status = 'COMPLETED';
\echo '--- E2b. status = NO_SHOW (~7% of rows) -> expect Bitmap Index Scan'
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON) SELECT max(reason) FROM appointment WHERE status = 'NO_SHOW';
\echo '--- E2c. count(*) on COMPLETED: here the narrow index IS used (Index Only Scan via visibility map)'
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON) SELECT count(*) FROM appointment WHERE status = 'COMPLETED';
DROP INDEX ix_tmp_status;

\echo '=== E3. Q4 (monthly revenue) did not benefit from indexes: it aggregates ~50k rows across 5 tables. ==='
\echo '=== Fix: pre-aggregate in a MATERIALIZED VIEW refreshed nightly (reporting workload). ==='
DROP MATERIALIZED VIEW IF EXISTS mv_monthly_department_revenue;
CREATE MATERIALIZED VIEW mv_monthly_department_revenue AS
SELECT date_trunc('month', pay.paid_at) AS month, d.department_id, sum(pay.amount) AS revenue, count(*) AS payments
FROM payment pay
JOIN invoice i     ON i.invoice_id = pay.invoice_id
JOIN appointment a ON a.appointment_id = i.appointment_id
JOIN doctor d      ON d.doctor_id = a.doctor_id
GROUP BY 1, 2;
CREATE UNIQUE INDEX ON mv_monthly_department_revenue(month, department_id);   -- allows REFRESH ... CONCURRENTLY
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT m.month, dep.name, m.revenue
FROM mv_monthly_department_revenue m JOIN department dep USING (department_id)
WHERE m.month >= '2026-01-01' AND m.month < '2027-01-01' ORDER BY 1, 2;
\echo '--- refresh cost (paid once per night instead of on every dashboard load)'
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_monthly_department_revenue;

\echo '=== E4. Q3 rewrite: aggregate diagnosis counts BEFORE joining dimension tables ==='
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
WITH dx_counts AS (
    SELECT d.department_id, dx.icd10_code, count(*) AS cases
    FROM diagnosis dx
    JOIN appointment a ON a.appointment_id = dx.appointment_id
    JOIN doctor d      ON d.doctor_id = a.doctor_id
    WHERE a.scheduled_start >= TIMESTAMPTZ '2025-10-31'
    GROUP BY d.department_id, dx.icd10_code
)
SELECT dep.name, r.rnk, r.icd10_code, r.cases
FROM (SELECT *, dense_rank() OVER (PARTITION BY department_id ORDER BY cases DESC) rnk FROM dx_counts) r
JOIN department dep USING (department_id)
WHERE r.rnk <= 3 ORDER BY dep.name, r.rnk;

\echo '=== E5. Index usage statistics since the benchmark started (run benchmark.py first) ==='
SELECT indexrelname AS index, idx_scan AS scans, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes WHERE schemaname = 'clinic' ORDER BY idx_scan DESC;

\echo '=== E6. Cost of indexes on writes: insert 5,000 appointments WITH vs WITHOUT the 3 extra appointment indexes ==='
\echo '--- E6a. with all indexes'
BEGIN;
INSERT INTO appointment(patient_id, doctor_id, scheduled_start, scheduled_end, status)
SELECT 1 + (g % 20000), 1 + (g % 60), TIMESTAMPTZ '2028-01-03 09:00' + (g / 60) * INTERVAL '15 minutes',
       TIMESTAMPTZ '2028-01-03 09:15' + (g / 60) * INTERVAL '15 minutes', 'BOOKED'
FROM generate_series(0, 4999) g;
ROLLBACK;
\echo '--- E6b. optimisation indexes on appointment dropped (inside the transaction, restored by ROLLBACK)'
BEGIN;
DROP INDEX ix_appointment_patient, ix_appointment_doctor_start, ix_appointment_start;
INSERT INTO appointment(patient_id, doctor_id, scheduled_start, scheduled_end, status)
SELECT 1 + (g % 20000), 1 + (g % 60), TIMESTAMPTZ '2028-01-03 09:00' + (g / 60) * INTERVAL '15 minutes',
       TIMESTAMPTZ '2028-01-03 09:15' + (g / 60) * INTERVAL '15 minutes', 'BOOKED'
FROM generate_series(0, 4999) g;
ROLLBACK;
