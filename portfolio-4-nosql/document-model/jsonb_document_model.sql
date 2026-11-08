-- =====================================================================
-- Portfolio 4 – Document model for the patient record (PostgreSQL JSONB)
-- One self-contained JSON document per patient: demographics, allergies,
-- and an embedded array of encounters (each with diagnoses, meds, labs).
-- This is the same aggregate a MongoDB collection would store (see ../mongodb/).
-- psql -d carepoint -f jsonb_document_model.sql > ../evidence/jsonb_output.txt 2>&1
-- =====================================================================
DROP SCHEMA IF EXISTS docstore CASCADE;
CREATE SCHEMA docstore;
SET search_path TO docstore, clinic;
SET max_parallel_workers_per_gather = 0;
\timing on

CREATE TABLE patient_record (
    hospital_no  CHAR(10) PRIMARY KEY,
    doc          JSONB    NOT NULL,
    -- light schema validation on a schemaless document
    CONSTRAINT doc_has_required CHECK (doc ? 'hospital_no' AND doc ? 'name' AND jsonb_typeof(doc->'encounters') = 'array')
);

\echo '=== D1. Build documents from the relational data (denormalise / embed) ==='
INSERT INTO patient_record(hospital_no, doc)
SELECT p.hospital_no,
  jsonb_build_object(
    'hospital_no', p.hospital_no,
    'name',        jsonb_build_object('first', p.first_name, 'last', p.last_name),
    'dob',         p.date_of_birth,
    'sex',         p.sex,
    'blood_group', p.blood_group,
    'contact',     jsonb_strip_nulls(jsonb_build_object('phone', p.phone, 'email', p.email, 'city', p.city, 'postcode', p.postcode)),
    'allergies',   COALESCE((SELECT jsonb_agg(jsonb_build_object('allergen', al.allergen, 'severity', al.severity))
                             FROM allergy al WHERE al.patient_id = p.patient_id), '[]'::jsonb),
    'encounters',  COALESCE((
        SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                 'date',       a.scheduled_start,
                 'status',     a.status,
                 'doctor',     d.first_name || ' ' || d.last_name,
                 'department', dep.name,
                 'diagnoses',  (SELECT jsonb_agg(dx.icd10_code) FROM diagnosis dx WHERE dx.appointment_id = a.appointment_id),
                 'medications',(SELECT jsonb_agg(jsonb_build_object('name', m.name, 'strength', m.strength, 'qty', pi.quantity))
                                FROM prescription pr JOIN prescription_item pi USING (prescription_id) JOIN medication m USING (medication_id)
                                WHERE pr.appointment_id = a.appointment_id),
                 'labs',       (SELECT jsonb_agg(jsonb_build_object('test', o.test_code, 'value', lr.result_value, 'flag', lr.flag))
                                FROM lab_order o JOIN lab_result lr USING (lab_order_id) WHERE o.appointment_id = a.appointment_id)
               )) ORDER BY a.scheduled_start)
        FROM appointment a JOIN doctor d USING (doctor_id) JOIN department dep USING (department_id)
        WHERE a.patient_id = p.patient_id), '[]'::jsonb)
  )
FROM patient p;

SELECT count(*) AS documents, pg_size_pretty(pg_total_relation_size('patient_record')) AS total_size,
       round(avg(pg_column_size(doc))) AS avg_doc_bytes, max(jsonb_array_length(doc->'encounters')) AS max_encounters
FROM patient_record;

\echo '=== D2. One sample document (whole patient history in ONE read, no joins) ==='
SELECT jsonb_pretty(doc) FROM patient_record WHERE hospital_no = 'CP00012345';

\echo '=== D3. GIN index for containment (@>) and jsonpath queries ==='
CREATE INDEX ix_patient_record_doc ON patient_record USING gin (doc jsonb_path_ops);
ANALYZE patient_record;

\echo '--- D3a. Patients with a SEVERE penicillin allergy (containment, uses GIN)'
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT hospital_no FROM patient_record
WHERE doc @> '{"allergies":[{"allergen":"Penicillin","severity":"SEVERE"}]}';
SELECT count(*) AS severe_penicillin FROM patient_record
WHERE doc @> '{"allergies":[{"allergen":"Penicillin","severity":"SEVERE"}]}';

\echo '--- D3b. Patients ever diagnosed with Type 2 diabetes (E11.9) AND prescribed Metformin'
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT hospital_no FROM patient_record
WHERE doc @> '{"encounters":[{"diagnoses":["E11.9"], "medications":[{"name":"Metformin"}]}]}';

\echo '--- D3c. jsonpath: encounters with an HbA1c result above 45 (filter inside each document)'
SELECT hospital_no, jsonb_path_query(doc, '$.encounters[*] ? (exists (@.labs[*] ? (@.test == "HBA1C" && @.value > 45)))') ->> 'date' AS encounter_date
FROM patient_record
WHERE doc @> '{"encounters":[{"labs":[{"test":"HBA1C","flag":"H"}]}]}'
LIMIT 5;

\echo '=== D4. Read performance: full history – document (1 row by PK) vs relational (9-table join) ==='
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT doc FROM patient_record WHERE hospital_no = 'CP00012345';

\echo '=== D5. Schema flexibility: add a new attribute to ONE document without ALTER TABLE ==='
UPDATE patient_record
SET doc = jsonb_set(doc, '{wearable}', '{"device":"SmartWatch X","resting_hr":[62,64,61],"synced":"2026-10-30"}')
WHERE hospital_no = 'CP00012345';
SELECT doc->'wearable' AS new_field FROM patient_record WHERE hospital_no = 'CP00012345';
SELECT count(*) FILTER (WHERE doc ? 'wearable') AS docs_with_wearable, count(*) AS all_docs FROM patient_record;

\echo '=== D6. The cost of denormalisation: renaming a doctor touches every embedded copy ==='
SELECT count(*) AS documents_mentioning_doctor
FROM patient_record WHERE doc @> '{"encounters":[{"doctor":"Grace Eze"}]}';
\echo '(In the relational model this is a 1-row UPDATE on doctor.)'
