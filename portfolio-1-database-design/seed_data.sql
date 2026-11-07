-- =====================================================================
-- CarePoint Clinic – Synthetic seed data (deterministic: setseed)
-- Volume is deliberately large (~140k appointments) so that query plans
-- in Portfolio 2 are meaningful. All people are fictional.
-- Run after schema.sql:  psql -U postgres -d carepoint -f seed_data.sql
-- =====================================================================
SET search_path TO clinic;
SELECT setseed(0.42);

INSERT INTO department(name, floor_location) VALUES
 ('General Practice','Ground A'),('Cardiology','Level 2 East'),('Paediatrics','Level 1 West'),
 ('Obstetrics & Gynaecology','Level 3'),('Orthopaedics','Level 2 West'),('Dermatology','Level 1 East'),
 ('Neurology','Level 4'),('Endocrinology','Level 3 East');

-- 60 doctors spread across departments
INSERT INTO doctor(licence_no, first_name, last_name, email, phone, specialisation, department_id)
SELECT 'LIC' || lpad(g::text, 6, '0'),
       (ARRAY['Ada','Tunde','Grace','Emeka','Fatima','Samuel','Chioma','David','Amaka','Ibrahim','Ruth','Kelechi'])[1 + g % 12],
       (ARRAY['Okafor','Adeyemi','Bello','Smith','Eze','Johnson','Lawal','Brown','Nwosu','Williams'])[1 + (g*7) % 10],
       'dr' || g || '@carepoint.example',
       '+44 7700 9' || lpad(g::text, 5, '0'),
       (ARRAY['General Practitioner','Cardiologist','Paediatrician','Obstetrician','Orthopaedic Surgeon',
              'Dermatologist','Neurologist','Endocrinologist'])[1 + (g-1) % 8],
       1 + (g-1) % 8
FROM generate_series(1, 60) g;

-- 20,000 patients
INSERT INTO patient(hospital_no, first_name, last_name, date_of_birth, sex, phone, email,
                    address_line, city, postcode, blood_group, registered_at)
SELECT 'CP' || lpad(g::text, 8, '0'),
       (ARRAY['Olu','Mary','John','Aisha','Peter','Zainab','James','Ngozi','Michael','Sarah','Yusuf','Chloe','Daniel','Funmi','Liam'])[1 + floor(random()*15)::int],
       (ARRAY['Adebayo','Taylor','Okeke','Hughes','Musa','Clarke','Obi','Evans','Abubakar','Wilson','Danjuma','Moore'])[1 + floor(random()*12)::int],
       DATE '1940-01-01' + floor(random() * 30000)::int,
       (ARRAY['F','M','F','M','X'])[1 + floor(random()*5)::int],
       '+44 7' || lpad(floor(random()*1e9)::text, 9, '0'),
       'patient' || g || '@mail.example',
       (1 + floor(random()*200))::int || ' High Street',
       (ARRAY['London','Manchester','Birmingham','Leeds','Bristol','Leicester'])[1 + floor(random()*6)::int],
       'AB' || (1 + floor(random()*99))::int || ' ' || (1 + floor(random()*9))::int || 'CD',
       (ARRAY['A+','A-','B+','B-','AB+','AB-','O+','O-'])[1 + floor(random()*8)::int],
       TIMESTAMPTZ '2020-01-01' + random() * INTERVAL '5 years'
FROM generate_series(1, 20000) g;

INSERT INTO allergy(patient_id, allergen, severity)
SELECT p.patient_id, a.allergen, (ARRAY['MILD','MODERATE','SEVERE'])[1 + floor(random()*3)::int]
FROM patient p
CROSS JOIN (VALUES ('Penicillin'),('Peanuts'),('Latex'),('Aspirin'),('Shellfish')) a(allergen)
WHERE random() < 0.04;

INSERT INTO icd10_code VALUES
 ('I10','Essential (primary) hypertension'),('E11.9','Type 2 diabetes mellitus without complications'),
 ('J06.9','Acute upper respiratory infection, unspecified'),('M54.5','Low back pain'),
 ('L20.9','Atopic dermatitis, unspecified'),('G43.9','Migraine, unspecified'),
 ('O80','Encounter for full-term uncomplicated delivery'),('J45.9','Asthma, unspecified'),
 ('I25.10','Atherosclerotic heart disease'),('E03.9','Hypothyroidism, unspecified'),
 ('S93.4','Sprain of ankle'),('K21.9','Gastro-oesophageal reflux disease'),
 ('F41.1','Generalised anxiety disorder'),('N39.0','Urinary tract infection'),('R51','Headache');

INSERT INTO medication(name, form, strength, unit_price, stock_qty) VALUES
 ('Amlodipine','TABLET','5mg',0.20,50000),('Metformin','TABLET','500mg',0.15,60000),
 ('Amoxicillin','CAPSULE','500mg',0.30,40000),('Ibuprofen','TABLET','400mg',0.10,80000),
 ('Paracetamol','TABLET','500mg',0.05,100000),('Salbutamol','INHALER','100mcg',3.50,5000),
 ('Levothyroxine','TABLET','50mcg',0.25,30000),('Omeprazole','CAPSULE','20mg',0.18,45000),
 ('Hydrocortisone','CREAM','1%',2.10,8000),('Sumatriptan','TABLET','50mg',0.90,9000),
 ('Atorvastatin','TABLET','20mg',0.22,50000),('Sertraline','TABLET','50mg',0.35,20000),
 ('Nitrofurantoin','CAPSULE','100mg',0.40,15000),('Insulin glargine','INJECTION','100u/ml',18.00,2000),
 ('Rare Antivenom','INJECTION','10ml',250.00,3);                 -- low stock: used in Portfolio 3

INSERT INTO lab_test VALUES
 ('FBC','Full blood count (Hb)','g/L',120,170,15.00),('HBA1C','HbA1c','mmol/mol',20,42,12.00),
 ('TSH','Thyroid stimulating hormone','mU/L',0.4,4.0,14.00),('LIPID','Total cholesterol','mmol/L',0,5,10.00),
 ('CRP','C-reactive protein','mg/L',0,5,9.00),('UE','Serum creatinine','umol/L',60,110,11.00);

-- Appointments: each doctor works weekdays 2025-01-01 .. 2026-12-31, 32 x 15-min slots/day,
-- ~15% of slots booked. Slots never overlap, so the exclusion constraint is respected.
INSERT INTO appointment(patient_id, doctor_id, scheduled_start, scheduled_end, status, reason, created_at)
SELECT 1 + floor(random()*20000)::int,
       d.doctor_id,
       s.slot,
       s.slot + INTERVAL '15 minutes',
       CASE WHEN s.slot > TIMESTAMPTZ '2026-10-31 00:00' THEN
                CASE WHEN random() < 0.05 THEN 'CANCELLED' ELSE 'BOOKED' END
            ELSE (ARRAY['COMPLETED','COMPLETED','COMPLETED','COMPLETED','COMPLETED','COMPLETED',
                        'COMPLETED','COMPLETED','COMPLETED','COMPLETED','COMPLETED','NO_SHOW','CANCELLED'])[1 + floor(random()*13)::int]
       END,
       (ARRAY['Routine check-up','Follow-up','New symptoms','Medication review','Test results','Referral'])[1 + floor(random()*6)::int],
       s.slot - (1 + floor(random()*30))::int * INTERVAL '1 day'
FROM doctor d
CROSS JOIN LATERAL (
    SELECT day + TIME '09:00' + k * INTERVAL '15 minutes' AS slot
    FROM generate_series(DATE '2025-01-01', DATE '2026-12-31', INTERVAL '1 day') day,
         generate_series(0, 31) k
    WHERE extract(isodow FROM day) < 6
) s
WHERE random() < 0.15;

-- One primary diagnosis per completed appointment; diagnosis loosely matches department
INSERT INTO diagnosis(appointment_id, icd10_code, is_primary, notes)
SELECT a.appointment_id,
       CASE d.department_id
         WHEN 2 THEN (ARRAY['I10','I25.10','I10'])[1 + floor(random()*3)::int]
         WHEN 3 THEN (ARRAY['J06.9','J45.9','L20.9'])[1 + floor(random()*3)::int]
         WHEN 4 THEN (ARRAY['O80','N39.0'])[1 + floor(random()*2)::int]
         WHEN 5 THEN (ARRAY['M54.5','S93.4'])[1 + floor(random()*2)::int]
         WHEN 6 THEN 'L20.9'
         WHEN 7 THEN (ARRAY['G43.9','R51'])[1 + floor(random()*2)::int]
         WHEN 8 THEN (ARRAY['E11.9','E03.9'])[1 + floor(random()*2)::int]
         ELSE (ARRAY['I10','E11.9','J06.9','M54.5','K21.9','F41.1','N39.0','R51'])[1 + floor(random()*8)::int]
       END,
       TRUE, 'Clinical notes recorded at consultation'
FROM appointment a JOIN doctor d USING (doctor_id)
WHERE a.status = 'COMPLETED';

-- Prescriptions for ~60% of completed appointments, 1-2 items each
INSERT INTO prescription(appointment_id, issued_at, dispensed)
SELECT appointment_id, scheduled_start + INTERVAL '20 minutes', random() < 0.9
FROM appointment WHERE status = 'COMPLETED' AND random() < 0.6;

INSERT INTO prescription_item(prescription_id, medication_id, dosage, frequency, duration_days, quantity)
SELECT DISTINCT ON (p.prescription_id, m.med)
       p.prescription_id, m.med, '1 unit', (ARRAY['Once daily','Twice daily','Three times daily'])[1 + floor(random()*3)::int],
       (ARRAY[5,7,14,28])[1 + floor(random()*4)::int], (ARRAY[10,14,28,56])[1 + floor(random()*4)::int]
FROM prescription p
CROSS JOIN LATERAL (SELECT 1 + floor(random()*14)::int AS med FROM generate_series(1, 1 + (p.prescription_id % 2)::int)) m;

-- Lab orders for ~30% of completed appointments
INSERT INTO lab_order(appointment_id, test_code, ordered_at, status)
SELECT appointment_id, (ARRAY['FBC','HBA1C','TSH','LIPID','CRP','UE'])[1 + floor(random()*6)::int],
       scheduled_start + INTERVAL '25 minutes', 'RESULTED'
FROM appointment WHERE status = 'COMPLETED' AND random() < 0.3;

INSERT INTO lab_result(lab_order_id, result_value, flag, resulted_at)
-- random() is kept in the SELECT list of a derived table so it is evaluated per row.
-- (An earlier version used CROSS JOIN LATERAL; PostgreSQL evaluated it once per test type,
--  giving every result the same value – caught when Q7 in Portfolio 2 returned no rows.)
SELECT lab_order_id, val,
       CASE WHEN val < ref_low THEN 'L' WHEN val > ref_high THEN 'H' ELSE 'N' END,
       ordered_at + INTERVAL '1 day'
FROM (SELECT o.lab_order_id, o.ordered_at, t.ref_low, t.ref_high,
             round((t.ref_low + (t.ref_high - t.ref_low) * (random()*1.6 - 0.3))::numeric, 2) AS val
      FROM lab_order o JOIN lab_test t USING (test_code)) x;

-- Invoices: consultation fee + lab tests
INSERT INTO invoice(appointment_id, total_amount, status, issued_at)
SELECT a.appointment_id, 45.00 + COALESCE(l.lab_total, 0),
       'UNPAID', a.scheduled_start + INTERVAL '30 minutes'
FROM appointment a
LEFT JOIN (SELECT o.appointment_id, sum(t.price) AS lab_total
           FROM lab_order o JOIN lab_test t USING (test_code) GROUP BY o.appointment_id) l
       ON l.appointment_id = a.appointment_id
WHERE a.status = 'COMPLETED';

INSERT INTO payment(invoice_id, amount, method, paid_at)
SELECT invoice_id, total_amount, (ARRAY['CASH','CARD','TRANSFER','INSURANCE'])[1 + floor(random()*4)::int],
       issued_at + (floor(random()*10))::int * INTERVAL '1 day'
FROM invoice WHERE random() < 0.92;

UPDATE invoice i SET status = 'PAID' WHERE EXISTS (SELECT 1 FROM payment p WHERE p.invoice_id = i.invoice_id);

ANALYZE;

-- Row counts for the README
SELECT 'department' t, count(*) FROM department UNION ALL SELECT 'doctor', count(*) FROM doctor
UNION ALL SELECT 'patient', count(*) FROM patient UNION ALL SELECT 'allergy', count(*) FROM allergy
UNION ALL SELECT 'appointment', count(*) FROM appointment UNION ALL SELECT 'diagnosis', count(*) FROM diagnosis
UNION ALL SELECT 'prescription', count(*) FROM prescription UNION ALL SELECT 'prescription_item', count(*) FROM prescription_item
UNION ALL SELECT 'lab_order', count(*) FROM lab_order UNION ALL SELECT 'lab_result', count(*) FROM lab_result
UNION ALL SELECT 'invoice', count(*) FROM invoice UNION ALL SELECT 'payment', count(*) FROM payment;
