-- =====================================================================
-- Portfolio 3 – Single-session transaction examples (COMMIT / ROLLBACK / SAVEPOINT)
-- psql -d carepoint -f transactions.sql > evidence/transactions_sql_output.txt 2>&1
-- =====================================================================
SET search_path TO clinic;
\set ON_ERROR_STOP off

-- Stored procedure: complete a consultation atomically.
-- Marks the appointment COMPLETED, records the diagnosis and raises the invoice.
-- Either ALL three happen or NONE (atomicity).
CREATE OR REPLACE PROCEDURE complete_consultation(p_appt BIGINT, p_icd VARCHAR, p_fee NUMERIC)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE appointment SET status = 'COMPLETED' WHERE appointment_id = p_appt AND status = 'BOOKED';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment % is not in BOOKED state', p_appt;
    END IF;
    INSERT INTO diagnosis(appointment_id, icd10_code, notes) VALUES (p_appt, p_icd, 'Recorded via procedure');
    INSERT INTO invoice(appointment_id, total_amount) VALUES (p_appt, p_fee);
END $$;

-- Stored procedure: dispense a prescription – decrements stock for every item.
CREATE OR REPLACE PROCEDURE dispense_prescription(p_rx BIGINT)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE medication m SET stock_qty = m.stock_qty - pi.quantity
    FROM prescription_item pi
    WHERE pi.prescription_id = p_rx AND pi.medication_id = m.medication_id;
    UPDATE prescription SET dispensed = TRUE WHERE prescription_id = p_rx;
END $$;

\echo '================ T1. COMMIT: complete a consultation (3 statements, 1 unit of work) ================'
SELECT appointment_id, status FROM appointment WHERE appointment_id = (SELECT min(appointment_id) FROM appointment WHERE status='BOOKED') \gset
\echo Appointment :appointment_id before:
SELECT appointment_id, status FROM appointment WHERE appointment_id = :appointment_id;
BEGIN;
CALL complete_consultation(:appointment_id, 'I10', 45.00);
COMMIT;
\echo After COMMIT – appointment, diagnosis and invoice all exist:
SELECT a.appointment_id, a.status, d.icd10_code, i.total_amount
FROM appointment a JOIN diagnosis d USING (appointment_id) JOIN invoice i USING (appointment_id)
WHERE a.appointment_id = :appointment_id;

\echo '================ T2. ROLLBACK on error: completing the SAME appointment again fails ================'
\echo (Atomicity: the procedure raises an exception, so nothing is half-written)
BEGIN;
CALL complete_consultation(:appointment_id, 'E11.9', 45.00);
ROLLBACK;
SELECT count(*) AS diagnoses_for_appt FROM diagnosis WHERE appointment_id = :appointment_id;

\echo '================ T3. ROLLBACK by CHECK constraint: dispensing more antivenom than in stock ================'
-- Build a prescription for 5 vials of Rare Antivenom (stock = 3) plus 28 Paracetamol
BEGIN;
INSERT INTO prescription(appointment_id) VALUES (:appointment_id) RETURNING prescription_id \gset rx_
INSERT INTO prescription_item VALUES (:rx_prescription_id, (SELECT medication_id FROM medication WHERE name='Paracetamol'), '1 tab','QDS',7,28),
                                     (:rx_prescription_id, (SELECT medication_id FROM medication WHERE name='Rare Antivenom'), '1 vial','STAT',1,5);
COMMIT;
\echo Stock before:
SELECT name, stock_qty FROM medication WHERE name IN ('Paracetamol','Rare Antivenom') ORDER BY name;
BEGIN;
CALL dispense_prescription(:rx_prescription_id);      -- fails: stock_qty would be -2
COMMIT;                                               -- in an aborted transaction COMMIT performs ROLLBACK
\echo Stock after – Paracetamol was NOT decremented either (all-or-nothing):
SELECT name, stock_qty FROM medication WHERE name IN ('Paracetamol','Rare Antivenom') ORDER BY name;
SELECT prescription_id, dispensed FROM prescription WHERE prescription_id = :rx_prescription_id;

\echo '================ T4. SAVEPOINT: order 3 lab tests, one has an invalid code – keep the valid ones ================'
BEGIN;
INSERT INTO lab_order(appointment_id, test_code) VALUES (:appointment_id, 'FBC');
SAVEPOINT before_second;
INSERT INTO lab_order(appointment_id, test_code) VALUES (:appointment_id, 'XRAY');   -- FK violation
ROLLBACK TO SAVEPOINT before_second;
INSERT INTO lab_order(appointment_id, test_code) VALUES (:appointment_id, 'HBA1C');
COMMIT;
SELECT lab_order_id, test_code, status FROM lab_order WHERE appointment_id = :appointment_id ORDER BY lab_order_id;

\echo '================ T5. Durability check: data committed in T1 is visible from a NEW session ================'
\c carepoint
SELECT appointment_id, status FROM clinic.appointment WHERE appointment_id = :appointment_id;
SELECT action, row_pk, old_data->>'status' AS old, new_data->>'status' AS new, changed_at
FROM clinic.audit_log WHERE row_pk = :'appointment_id' ORDER BY audit_id;
