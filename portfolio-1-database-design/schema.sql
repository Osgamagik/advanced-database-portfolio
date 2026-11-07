-- =====================================================================
-- CarePoint Clinic – Relational Schema (PostgreSQL 16)
-- Portfolio 1: Database Design and Modelling
-- Run:  psql -U postgres -d carepoint -f schema.sql
-- =====================================================================

DROP SCHEMA IF EXISTS clinic CASCADE;
CREATE SCHEMA clinic;
SET search_path TO clinic;

CREATE EXTENSION IF NOT EXISTS btree_gist;   -- used by the overlap-exclusion constraint

-- ---------------------------------------------------------------------
-- Reference / master data
-- ---------------------------------------------------------------------
CREATE TABLE department (
    department_id   SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            VARCHAR(80)  NOT NULL UNIQUE,
    floor_location  VARCHAR(40)  NOT NULL
);

CREATE TABLE doctor (
    doctor_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    licence_no      VARCHAR(20)  NOT NULL UNIQUE,              -- e.g. GMC number
    first_name      VARCHAR(50)  NOT NULL,
    last_name       VARCHAR(50)  NOT NULL,
    email           VARCHAR(120) NOT NULL UNIQUE,
    phone           VARCHAR(20),
    specialisation  VARCHAR(60)  NOT NULL,
    department_id   SMALLINT     NOT NULL REFERENCES department(department_id),
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE
);

CREATE TABLE patient (
    patient_id      INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    hospital_no     CHAR(10)     NOT NULL UNIQUE,              -- business key printed on wristband
    first_name      VARCHAR(50)  NOT NULL,
    last_name       VARCHAR(50)  NOT NULL,
    date_of_birth   DATE         NOT NULL CHECK (date_of_birth <= CURRENT_DATE),
    sex             CHAR(1)      NOT NULL CHECK (sex IN ('F','M','X')),
    phone           VARCHAR(20),
    email           VARCHAR(120),
    address_line    VARCHAR(120),
    city            VARCHAR(60),
    postcode        VARCHAR(10),
    blood_group     VARCHAR(3)   CHECK (blood_group IN ('A+','A-','B+','B-','AB+','AB-','O+','O-')),
    registered_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE allergy (                                         -- multi-valued attribute -> own table (1NF)
    patient_id      INT          NOT NULL REFERENCES patient(patient_id) ON DELETE CASCADE,
    allergen        VARCHAR(60)  NOT NULL,
    severity        VARCHAR(10)  NOT NULL CHECK (severity IN ('MILD','MODERATE','SEVERE')),
    PRIMARY KEY (patient_id, allergen)
);

CREATE TABLE icd10_code (
    code            VARCHAR(7)   PRIMARY KEY,
    description     VARCHAR(200) NOT NULL
);

CREATE TABLE medication (
    medication_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            VARCHAR(80)  NOT NULL,
    form            VARCHAR(20)  NOT NULL CHECK (form IN ('TABLET','CAPSULE','SYRUP','INJECTION','INHALER','CREAM')),
    strength        VARCHAR(20)  NOT NULL,
    unit_price      NUMERIC(8,2) NOT NULL CHECK (unit_price >= 0),
    stock_qty       INT          NOT NULL CHECK (stock_qty >= 0), -- stock can never go negative
    UNIQUE (name, form, strength)
);

CREATE TABLE lab_test (
    test_code       VARCHAR(10)  PRIMARY KEY,
    name            VARCHAR(80)  NOT NULL,
    unit            VARCHAR(20),
    ref_low         NUMERIC(10,2),
    ref_high        NUMERIC(10,2),
    price           NUMERIC(8,2) NOT NULL CHECK (price >= 0),
    CHECK (ref_low IS NULL OR ref_high IS NULL OR ref_low <= ref_high)
);

-- ---------------------------------------------------------------------
-- Transactional data
-- ---------------------------------------------------------------------
CREATE TABLE appointment (
    appointment_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id      INT          NOT NULL REFERENCES patient(patient_id),
    doctor_id       INT          NOT NULL REFERENCES doctor(doctor_id),
    scheduled_start TIMESTAMPTZ  NOT NULL,
    scheduled_end   TIMESTAMPTZ  NOT NULL,
    CHECK (scheduled_end > scheduled_start AND scheduled_end <= scheduled_start + INTERVAL '2 hours'),
    status          VARCHAR(10)  NOT NULL DEFAULT 'BOOKED'
                    CHECK (status IN ('BOOKED','COMPLETED','CANCELLED','NO_SHOW')),
    reason          VARCHAR(200),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    -- A doctor can never have two overlapping live appointments (advanced constraint)
    CONSTRAINT no_doctor_double_booking EXCLUDE USING gist (
        doctor_id WITH =,
        tstzrange(scheduled_start, scheduled_end) WITH &&
    ) WHERE (status <> 'CANCELLED')
);

CREATE TABLE diagnosis (
    diagnosis_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    appointment_id  BIGINT       NOT NULL REFERENCES appointment(appointment_id),
    icd10_code      VARCHAR(7)   NOT NULL REFERENCES icd10_code(code),
    is_primary      BOOLEAN      NOT NULL DEFAULT TRUE,
    notes           TEXT,
    UNIQUE (appointment_id, icd10_code)
);

CREATE TABLE prescription (
    prescription_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    appointment_id  BIGINT       NOT NULL REFERENCES appointment(appointment_id),
    issued_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    dispensed       BOOLEAN      NOT NULL DEFAULT FALSE
);

CREATE TABLE prescription_item (                               -- resolves M:N prescription <-> medication
    prescription_id BIGINT       NOT NULL REFERENCES prescription(prescription_id) ON DELETE CASCADE,
    medication_id   INT          NOT NULL REFERENCES medication(medication_id),
    dosage          VARCHAR(40)  NOT NULL,
    frequency       VARCHAR(40)  NOT NULL,
    duration_days   SMALLINT     NOT NULL CHECK (duration_days > 0),
    quantity        INT          NOT NULL CHECK (quantity > 0),
    PRIMARY KEY (prescription_id, medication_id)
);

CREATE TABLE lab_order (
    lab_order_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    appointment_id  BIGINT       NOT NULL REFERENCES appointment(appointment_id),
    test_code       VARCHAR(10)  NOT NULL REFERENCES lab_test(test_code),
    ordered_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    status          VARCHAR(10)  NOT NULL DEFAULT 'ORDERED'
                    CHECK (status IN ('ORDERED','COLLECTED','RESULTED','CANCELLED'))
);

CREATE TABLE lab_result (                                      -- 1:1 with lab_order (weak entity)
    lab_order_id    BIGINT       PRIMARY KEY REFERENCES lab_order(lab_order_id) ON DELETE CASCADE,
    result_value    NUMERIC(10,2) NOT NULL,
    flag            CHAR(1)      CHECK (flag IN ('L','N','H')),
    resulted_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE invoice (
    invoice_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    appointment_id  BIGINT       NOT NULL UNIQUE REFERENCES appointment(appointment_id),
    total_amount    NUMERIC(10,2) NOT NULL CHECK (total_amount >= 0),
    status          VARCHAR(10)  NOT NULL DEFAULT 'UNPAID' CHECK (status IN ('UNPAID','PART_PAID','PAID','VOID')),
    issued_at       TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE payment (
    payment_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_id      BIGINT       NOT NULL REFERENCES invoice(invoice_id),
    amount          NUMERIC(10,2) NOT NULL CHECK (amount > 0),
    method          VARCHAR(10)  NOT NULL CHECK (method IN ('CASH','CARD','TRANSFER','INSURANCE')),
    paid_at         TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Audit table populated by trigger (used again in Portfolio 3)
CREATE TABLE audit_log (
    audit_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name      TEXT         NOT NULL,
    row_pk          TEXT         NOT NULL,
    action          TEXT         NOT NULL,
    old_data        JSONB,
    new_data        JSONB,
    changed_by      TEXT         NOT NULL DEFAULT current_user,
    changed_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION trg_audit_appointment() RETURNS trigger AS $$
BEGIN
    INSERT INTO audit_log(table_name, row_pk, action, old_data, new_data)
    VALUES ('appointment', COALESCE(NEW.appointment_id, OLD.appointment_id)::text, TG_OP,
            CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END,
            CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END);
    RETURN NULL;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER audit_appointment_status
AFTER UPDATE OF status OR DELETE ON appointment
FOR EACH ROW EXECUTE FUNCTION trg_audit_appointment();

-- Convenience view: one row per appointment with names resolved
CREATE VIEW v_appointment_detail AS
SELECT a.appointment_id, a.scheduled_start, a.status,
       p.hospital_no, p.first_name || ' ' || p.last_name AS patient_name,
       d.first_name || ' ' || d.last_name AS doctor_name, dep.name AS department
FROM appointment a
JOIN patient p   ON p.patient_id = a.patient_id
JOIN doctor d    ON d.doctor_id = a.doctor_id
JOIN department dep ON dep.department_id = d.department_id;
