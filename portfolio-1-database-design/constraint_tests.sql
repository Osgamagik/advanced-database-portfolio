-- =====================================================================
-- Constraint tests – each statement below is EXPECTED TO FAIL.
-- Proves the integrity rules in schema.sql are enforced by the DBMS.
-- Run: psql -U postgres -d carepoint -f constraint_tests.sql
-- =====================================================================
SET search_path TO clinic;
\set ON_ERROR_STOP off
\echo '--- Test 1: double-booking a doctor (EXCLUDE constraint) ---'
WITH a AS (SELECT doctor_id, scheduled_start FROM appointment WHERE status = 'BOOKED' LIMIT 1)
INSERT INTO appointment(patient_id, doctor_id, scheduled_start, scheduled_end, status)
SELECT 1, doctor_id, scheduled_start + INTERVAL '5 minutes', scheduled_start + INTERVAL '20 minutes', 'BOOKED' FROM a;

\echo '--- Test 2: negative medication stock (CHECK) ---'
UPDATE medication SET stock_qty = -1 WHERE name = 'Paracetamol';

\echo '--- Test 3: duplicate hospital number (UNIQUE) ---'
INSERT INTO patient(hospital_no, first_name, last_name, date_of_birth, sex)
VALUES ('CP00000001', 'Dup', 'Licate', '1990-01-01', 'F');

\echo '--- Test 4: appointment for a non-existent patient (FOREIGN KEY) ---'
INSERT INTO appointment(patient_id, doctor_id, scheduled_start, scheduled_end)
VALUES (999999, 1, '2027-03-01 09:00', '2027-03-01 09:15');

\echo '--- Test 5: invalid status value (CHECK / domain) ---'
UPDATE appointment SET status = 'LOST' WHERE appointment_id = 1;

\echo '--- Test 6: date of birth in the future (CHECK) ---'
INSERT INTO patient(hospital_no, first_name, last_name, date_of_birth, sex)
VALUES ('CP99999999', 'Future', 'Baby', CURRENT_DATE + 10, 'M');

\echo '--- Test 7: end time before start time (CHECK) ---'
INSERT INTO appointment(patient_id, doctor_id, scheduled_start, scheduled_end)
VALUES (1, 1, '2027-03-01 10:00', '2027-03-01 09:45');

\echo '--- Test 8: a CANCELLED appointment does NOT block the slot (partial EXCLUDE) — expected to SUCCEED ---'
BEGIN;
WITH a AS (UPDATE appointment SET status = 'CANCELLED'
           WHERE appointment_id = (SELECT min(appointment_id) FROM appointment WHERE status = 'BOOKED')
           RETURNING doctor_id, scheduled_start, scheduled_end)
INSERT INTO appointment(patient_id, doctor_id, scheduled_start, scheduled_end, status)
SELECT 2, doctor_id, scheduled_start, scheduled_end, 'BOOKED' FROM a RETURNING appointment_id, doctor_id, scheduled_start;
SELECT action, row_pk, old_data->>'status' AS old_status, new_data->>'status' AS new_status
FROM audit_log ORDER BY audit_id DESC LIMIT 1;   -- trigger captured the status change
ROLLBACK;
