-- =====================================================================
-- CarePoint Clinic – Optimisation indexes (Portfolio 2)
-- Each index targets a specific query in queries.sql. Rationale in README.
-- =====================================================================
SET search_path TO clinic;

-- Q1, Q5, Q7: FK join appointment -> patient (PostgreSQL does not auto-index FKs)
CREATE INDEX IF NOT EXISTS ix_appointment_patient       ON appointment (patient_id, scheduled_start);

-- Q2, Q8: composite index – equality column first, range column second
CREATE INDEX IF NOT EXISTS ix_appointment_doctor_start  ON appointment (doctor_id, scheduled_start) INCLUDE (status, patient_id);

-- Q3, Q4: range filter on time across all doctors
CREATE INDEX IF NOT EXISTS ix_appointment_start         ON appointment (scheduled_start);

-- Q1: child-side FK indexes
-- (No separate index on diagnosis(appointment_id): the UNIQUE(appointment_id, icd10_code)
--  constraint index already has appointment_id as its leading column, so it serves the join.
--  An earlier version added one; the plans showed it was never chosen -> removed as redundant.)
CREATE INDEX IF NOT EXISTS ix_prescription_appointment  ON prescription (appointment_id);
CREATE INDEX IF NOT EXISTS ix_lab_order_appointment     ON lab_order (appointment_id);
CREATE INDEX IF NOT EXISTS ix_payment_invoice           ON payment (invoice_id);

-- Q4: range on payment date, covering the amount so the heap need not be visited
CREATE INDEX IF NOT EXISTS ix_payment_paid_at           ON payment (paid_at) INCLUDE (invoice_id, amount);

-- Q5: PARTIAL index – only ~8% of invoices are unpaid, so the index is tiny
CREATE INDEX IF NOT EXISTS ix_invoice_unpaid            ON invoice (issued_at) WHERE status = 'UNPAID';

-- Q6: EXPRESSION index with text_pattern_ops so LIKE 'prefix%' on lower() can use a B-tree
CREATE INDEX IF NOT EXISTS ix_patient_lower_lastname    ON patient (lower(last_name) text_pattern_ops, date_of_birth);

-- Q7: lab results by recency, only abnormal-high flags (partial)
CREATE INDEX IF NOT EXISTS ix_lab_result_high_recent    ON lab_result (resulted_at) WHERE flag = 'H';

ANALYZE;
