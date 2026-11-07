# Advanced Database Systems Portfolio – MIT 8103

**Student:** OSENI OLUWAGBEMIGA · 2026/A/MIT/0280  ·  **Programme:** Master of Information Technology, MIVA Open University  ·  **Session:** 2026/2027 First Semester

## Selected case study: CarePoint Clinic (simulated organisation)

CarePoint Clinic is a fictional multi-specialty outpatient clinic: 8 departments, 60 doctors and about 20,000 registered patients. It is expanding to a second site and launching a patient app.

| | |
|---|---|
| **Users** | Reception, doctors, pharmacy, laboratory, finance, management, patients (mobile app) |
| **Major data** | Patients, allergies, doctors, departments, appointments, diagnoses (ICD-10), medications and stock, prescriptions, lab orders and results, invoices, payments, audit log |
| **Key operations** | Register patient · book or cancel appointment (no double-booking) · record diagnosis · prescribe and dispense (stock control) · order tests and record results · invoice and payment · patient history · management reporting |

All five portfolio activities use this case study and the same synthetic dataset (about 150k appointments). The data is generated deterministically by `portfolio-1-database-design/seed_data.sql`, and all names are fictional.

## Repository structure

```
advanced-database-portfolio/
├── portfolio-1-database-design/      ERD, schema.sql, seed_data.sql, constraint tests, normalisation
├── portfolio-2-query-optimisation/   8 queries, indexes, EXPLAIN ANALYZE before/after, experiments
├── portfolio-3-transactions-concurrency/  COMMIT/ROLLBACK/SAVEPOINT, 5 concurrency scenarios
├── portfolio-4-nosql/                Redis key-value model, JSONB document model, MongoDB scripts
├── portfolio-5-distributed-cloud/    streaming replication + failover, sharding, AWS design
├── docs/                             AI-use declaration, reflection, references
└── README.md
```
Each folder has its own README explaining what was implemented, how to run it and what the evidence shows. Raw outputs are in each `evidence/` folder.

## Summary of results

| Portfolio | Highlights |
|---|---|
| 1. Design | 15 tables in 3NF/BCNF; a **GiST exclusion constraint** prevents overlapping doctor bookings; audit trigger; 8 constraint tests |
| 2. Optimisation | FK, composite, covering, partial and expression indexes made OLTP queries **7×–315× faster**. Analytical queries are better served by a materialised view (≈750×). Write overhead about 8%. |
| 3. Transactions | Atomic consultation and dispensing procedures. Lost update, non-repeatable read, **write skew** (prevented only by SERIALIZABLE), double-booking race and deadlock were each reproduced and fixed. |
| 4. NoSQL | Redis: cache (3.7× faster), queue, atomic slot booking, WATCH/MULTI, Streams. Document model: patient record in JSONB with a GIN index (single read, 0.02 ms). Polyglot persistence recommended. |
| 5. Distributed | Streaming replication: lag, sync vs async (+44% commit latency), CAP demonstration, **failover in 138 ms**. Hash sharding on patient_id with partition pruning. AWS Multi-AZ design. |

## How to reproduce

Requirements: PostgreSQL 16, Python 3.10+ (`pip install psycopg2-binary redis`), Redis 7.

```bash
createdb carepoint
psql -d carepoint -f portfolio-1-database-design/schema.sql
psql -d carepoint -f portfolio-1-database-design/seed_data.sql
# then follow each portfolio's README in order (2 → 5)
```
The environment variables `PGHOST`, `PGUSER`, `PGPASSWORD` and `PGDATABASE` configure the Python scripts (defaults: localhost / postgres / postgres / carepoint).

## Documentation
- `docs/AI_USE_DECLARATION.md`: AI tools used, what for, and how the output was verified
- `docs/REFLECTION.md`: individual technical reflection
- `docs/REFERENCES.md`: sources and documentation used
