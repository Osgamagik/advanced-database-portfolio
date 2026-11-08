-- =====================================================================
-- CarePoint Clinic – Portfolio 2 workload queries
-- Each query is preceded by a "-- name: Qn ..." marker; benchmark.py
-- splits on these markers and runs EXPLAIN (ANALYZE, BUFFERS) on each.
-- =====================================================================

-- name: Q1 Full clinical history of one patient (reception / doctor screen)
SELECT a.scheduled_start, a.status, d.last_name AS doctor, dep.name AS department,
       dx.icd10_code, c.description, string_agg(m.name || ' ' || m.strength, ', ') AS medications
FROM clinic.patient p
JOIN clinic.appointment a  ON a.patient_id = p.patient_id
JOIN clinic.doctor d       ON d.doctor_id = a.doctor_id
JOIN clinic.department dep ON dep.department_id = d.department_id
LEFT JOIN clinic.diagnosis dx  ON dx.appointment_id = a.appointment_id
LEFT JOIN clinic.icd10_code c  ON c.code = dx.icd10_code
LEFT JOIN clinic.prescription pr ON pr.appointment_id = a.appointment_id
LEFT JOIN clinic.prescription_item pi ON pi.prescription_id = pr.prescription_id
LEFT JOIN clinic.medication m  ON m.medication_id = pi.medication_id
WHERE p.hospital_no = 'CP00012345'
GROUP BY a.appointment_id, a.scheduled_start, a.status, d.last_name, dep.name, dx.icd10_code, c.description
ORDER BY a.scheduled_start DESC;

-- name: Q2 A doctor's schedule for one day (most frequent query in the clinic)
SELECT a.appointment_id, a.scheduled_start, a.status, p.hospital_no, p.first_name, p.last_name
FROM clinic.appointment a
JOIN clinic.patient p ON p.patient_id = a.patient_id
WHERE a.doctor_id = 17
  AND a.scheduled_start >= TIMESTAMPTZ '2026-11-03 00:00'
  AND a.scheduled_start <  TIMESTAMPTZ '2026-11-04 00:00'
  AND a.status <> 'CANCELLED'
ORDER BY a.scheduled_start;

-- name: Q3 Top-3 diagnoses per department in the last 12 months (CTE + window function)
WITH dx_counts AS (
    SELECT dep.name AS department, dx.icd10_code, count(*) AS cases
    FROM clinic.diagnosis dx
    JOIN clinic.appointment a  ON a.appointment_id = dx.appointment_id
    JOIN clinic.doctor d       ON d.doctor_id = a.doctor_id
    JOIN clinic.department dep ON dep.department_id = d.department_id
    WHERE a.scheduled_start >= TIMESTAMPTZ '2025-10-31'
    GROUP BY dep.name, dx.icd10_code
), ranked AS (
    SELECT *, dense_rank() OVER (PARTITION BY department ORDER BY cases DESC) AS rnk
    FROM dx_counts
)
SELECT department, rnk, icd10_code, cases FROM ranked WHERE rnk <= 3 ORDER BY department, rnk;

-- name: Q4 Monthly revenue collected per department for 2026
SELECT date_trunc('month', pay.paid_at) AS month, dep.name AS department, sum(pay.amount) AS revenue
FROM clinic.payment pay
JOIN clinic.invoice i      ON i.invoice_id = pay.invoice_id
JOIN clinic.appointment a  ON a.appointment_id = i.appointment_id
JOIN clinic.doctor d       ON d.doctor_id = a.doctor_id
JOIN clinic.department dep ON dep.department_id = d.department_id
WHERE pay.paid_at >= TIMESTAMPTZ '2026-01-01' AND pay.paid_at < TIMESTAMPTZ '2027-01-01'
GROUP BY 1, 2
ORDER BY 1, 2;

-- name: Q5 Outstanding (unpaid) invoices older than 30 days – finance chase list
SELECT i.invoice_id, i.issued_at, i.total_amount, p.hospital_no, p.phone
FROM clinic.invoice i
JOIN clinic.appointment a ON a.appointment_id = i.appointment_id
JOIN clinic.patient p     ON p.patient_id = a.patient_id
WHERE i.status = 'UNPAID' AND i.issued_at < TIMESTAMPTZ '2026-10-01'
ORDER BY i.issued_at
LIMIT 50;

-- name: Q6 Case-insensitive patient search by surname prefix (reception search box)
SELECT patient_id, hospital_no, first_name, last_name, date_of_birth
FROM clinic.patient
WHERE lower(last_name) LIKE 'oke%' AND date_of_birth BETWEEN DATE '1980-01-01' AND DATE '1985-12-31'
ORDER BY last_name, first_name;

-- name: Q7 Patients with an abnormal (high) HbA1c who have NOT been seen in Endocrinology since
SELECT DISTINCT p.hospital_no, p.last_name, r.result_value, r.resulted_at
FROM clinic.lab_result r
JOIN clinic.lab_order o   ON o.lab_order_id = r.lab_order_id
JOIN clinic.appointment a ON a.appointment_id = o.appointment_id
JOIN clinic.patient p     ON p.patient_id = a.patient_id
WHERE o.test_code = 'HBA1C' AND r.flag = 'H' AND r.resulted_at >= TIMESTAMPTZ '2026-09-01'
  AND NOT EXISTS (
        SELECT 1 FROM clinic.appointment a2 JOIN clinic.doctor d2 ON d2.doctor_id = a2.doctor_id
        WHERE a2.patient_id = p.patient_id AND d2.department_id = 8
          AND a2.scheduled_start > r.resulted_at)
ORDER BY r.resulted_at DESC;

-- name: Q8 No-show rate per doctor in 2026 (aggregate + FILTER)
SELECT d.doctor_id, d.last_name,
       count(*) FILTER (WHERE a.status = 'NO_SHOW')                          AS no_shows,
       count(*)                                                              AS total,
       round(100.0 * count(*) FILTER (WHERE a.status = 'NO_SHOW') / count(*), 2) AS no_show_pct
FROM clinic.appointment a JOIN clinic.doctor d ON d.doctor_id = a.doctor_id
WHERE a.scheduled_start >= TIMESTAMPTZ '2026-01-01' AND a.scheduled_start < TIMESTAMPTZ '2026-10-31'
GROUP BY d.doctor_id, d.last_name
ORDER BY no_show_pct DESC
LIMIT 10;
