# Portfolio 4 – NoSQL and Advanced Data Models

**Case study:** CarePoint Clinic. The NoSQL models are built on the **same data** as Portfolios 1–3 and are loaded from the PostgreSQL system of record.

Two NoSQL models were implemented and tested:

| Model | Technology | CarePoint use | Evidence |
|---|---|---|---|
| **Key-value / data-structure store** | Redis 7.0 | Real-time, short-lived, high-frequency data: patient cache, waiting-room queue, free slots, lab notifications, live dashboard, sessions | `redis/redis_demo.py` → `evidence/redis_output.txt` |
| **Document model** | PostgreSQL 16 JSONB with a GIN index (executed). MongoDB scripts provided. | One self-contained *patient record* document holding the full history | `document-model/jsonb_document_model.sql` → `evidence/jsonb_output.txt`; `mongodb/` |

> MongoDB was not available in the build environment, so the document model was executed in PostgreSQL JSONB, which has the same document semantics. The equivalent MongoDB validator, indexes and queries are in `mongodb/mongo_patient_records.js`, together with 500 exported documents. **To-do (student):** run them on MongoDB Atlas (free tier) and add screenshots to `evidence/`.

```bash
redis-server --daemonize yes
python3 redis/redis_demo.py | tee evidence/redis_output.txt
psql -d carepoint -f document-model/jsonb_document_model.sql > evidence/jsonb_output.txt 2>&1
```

---

## 1. Key-value model (Redis)

### Key design (naming convention `entity:id[:qualifier]`)

| Key pattern | Redis type | Purpose | Why this structure |
|---|---|---|---|
| `patient:{hospital_no}` | Hash, TTL 900 s | Cached patient summary (name, allergies, last diagnosis) | Field-level reads, auto-expiry keeps the cache fresh |
| `queue:doctor:{id}:{date}` | Sorted Set (score = check-in time) | Waiting-room queue | `ZPOPMIN` is atomic. Urgent patients can jump ahead by being given an earlier score |
| `slots:doctor:{id}:{date}` | Set | Free appointment slots | `SREM` returns 1 to exactly one client, so there is no double booking |
| `upcoming:{hospital_no}` | List | Patient's upcoming bookings for the mobile app | Ordered, append-only |
| `lab:results` | Stream + consumer group | Push abnormal lab results to doctors' tablets | Persistent, with acknowledgements and redelivery (at-least-once) |
| `dash:consults:{date}` | Sorted Set | Live "busiest doctors" leaderboard | `ZINCRBY` is O(log n) and the ranking is always sorted |
| `session:{token}` | String, `EX` | Login sessions | Expire automatically |

### Results (`evidence/redis_output.txt`)

| # | Scenario | Result |
|---|---|---|
| K1 | Cache-aside patient summary | First call MISS (loaded from PostgreSQL), second call HIT. Over 200 patients the median latency was **0.59 ms (PostgreSQL) vs 0.16 ms (Redis)**, 3.7× faster, and it takes read load off the primary database. On a write (for example a new allergy) the cache entry is invalidated with `DEL`. |
| K2 | Waiting-room queue | Ordered by check-in time. `ZPOPMIN` atomically gave the doctor the earliest patient. An urgent patient was placed first by giving them an earlier score. |
| K3 | Three clients race for the 10:00 slot | `{'recept_A': 1, 'online_portal': 0, 'recept_B': 0}`, so **exactly one winner**. Redis is single-threaded per command, so each command is atomic. |
| K4 | `WATCH`/`MULTI`/`EXEC` | Optimistic transaction (compare with Portfolio 3, C1-C). Another client took 11:15 after WATCH, so `EXEC` was aborted with WatchError. The retry saw the slot was gone, and no half-written state was left (the upcoming list stayed empty). |
| K5 | Lab-result stream | 4 high results published. The consumer read 3 and acknowledged 2. **1 is still pending** and would be redelivered if the tablet crashed. |
| K6 | Live dashboard | Top-5 doctors for 30 Oct 2026, built from `ZINCRBY` events. |
| K7 | Session expiry | The token disappeared after its 2 s TTL with no clean-up job. |

---

## 2. Document model (patient record aggregate)

### Model
One document per patient, embedding everything that is **read together**:

```json
{ "hospital_no": "CP00012345",
  "name": {"first": "Michael", "last": "Abubakar"}, "dob": "1957-06-30", "blood_group": "A-",
  "contact": {"city": "Leeds", "phone": "…"},
  "allergies": [ {"allergen": "Latex", "severity": "SEVERE"} ],
  "encounters": [
     { "date": "2025-03-19T10:30:00+00:00", "doctor": "Amaka Lawal", "department": "Endocrinology",
       "status": "COMPLETED", "diagnoses": ["E03.9"],
       "medications": [{"name": "Atorvastatin", "strength": "20mg", "qty": 28}],
       "labs": [{"test": "CRP", "value": 2.56, "flag": "N"}] } ] }
```
The full example is in `mongodb/sample_patient_document.json`.

**Embed vs reference decisions**
- **Embedded:** allergies and encounters (with their diagnoses, medications and labs). They are owned by the patient, always read with the patient, and bounded in size (at most 20 encounters per patient in our data, about 1.4 KB per document on average).
- **Copied in, not referenced:** doctor name and department name. This is denormalised for read speed (see the trade-off in D6).
- **Kept outside the document:** medication stock, invoices and payments. These are high-contention, transactional and shared across patients, so they belong in the relational store (Portfolio 3).

### Results (`evidence/jsonb_output.txt`)

| # | Test | Result |
|---|---|---|
| D1 | Built 20,000 documents from the relational tables | 29 MB, average 1,373 bytes per document |
| D2/D4 | Full history for one patient | **1 primary-key lookup, 0.024 ms**, compared with the 9-table join in Portfolio 2 Q1 (0.18 ms even after indexing). The aggregate is pre-joined. |
| D3a | `doc @> {"allergies":[{"allergen":"Penicillin","severity":"SEVERE"}]}` | Bitmap Index Scan on the **GIN** index: 241 patients in 1.3 ms |
| D3b | Diabetes diagnosis **and** Metformin in the same encounter | GIN index used: 539 patients in 16 ms |
| D3c | jsonpath filter *inside* each document (HbA1c > 45) | Shows querying nested arrays without unnesting into tables |
| D5 | Add a `wearable` sub-document to one patient | No `ALTER TABLE` and no migration. 1 of 20,000 documents has the field (**schema flexibility**). |
| D6 | Denormalisation cost | Renaming the doctor "Grace Eze" would mean rewriting **2,385 documents**, where the relational model needs a 1-row UPDATE |

---

## 3. Suitability: when should CarePoint use which model?

| Requirement | Best fit | Reason |
|---|---|---|
| Billing, payments, stock, booking integrity | **Relational** | ACID across many entities, FK/CHECK/EXCLUDE constraints, concurrency control (Portfolio 3) |
| Patient summary screen, mobile app "my record", data exchange (for example HL7 FHIR, which is itself JSON) | **Document** | Whole aggregate read in one operation, nested structure matches the screen, flexible fields such as wearables and new tests |
| Queues, live dashboards, notifications, sessions, caching | **Key-value (Redis)** | In-memory sub-millisecond operations, atomic data-structure commands, TTLs, streams |
| "Which doctors share patients?", referral networks | Graph (for example Neo4j) | Not implemented. Many-hop relationship traversals are where a graph model would add value. |
| Wearable heart-rate time series | Wide-column or time-series (Cassandra, TimescaleDB) | Not implemented. High write rate, append-only data partitioned by patient and day. |

**Conclusion: polyglot persistence.** PostgreSQL stays the system of record. Redis sits in front of it for real-time features. Patient-record documents are generated from the relational data for read-heavy and integration workloads.

**Trade-offs:**
- Document stores give up joins and cross-document integrity. D6 shows the update anomaly that normalisation was designed to prevent (Portfolio 1).
- Redis data lives in memory, so durability depends on AOF or RDB persistence settings. It must never be the only copy of clinical data.
