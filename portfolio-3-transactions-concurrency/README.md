# Portfolio 3 – Transactions and Concurrency

**Case study:** CarePoint Clinic. **DBMS:** PostgreSQL 16 (MVCC). **Client:** Python 3 + psycopg2, using real concurrent sessions.

## Files

| File | Purpose |
|---|---|
| `transactions.sql` | Stored procedures `complete_consultation` and `dispense_prescription`; demos T1–T5 (COMMIT, ROLLBACK, SAVEPOINT, durability) |
| `concurrency_demo.py` | Scenarios C1–C5: two or more sessions interleaved deterministically with `threading.Event`/`Barrier`, so the anomalies reproduce on every run |
| `evidence/transactions_sql_output.txt` | Output of `transactions.sql` |
| `evidence/concurrency_output.txt` | Timestamped output of `concurrency_demo.py` |

```bash
psql -d carepoint -f transactions.sql > evidence/transactions_sql_output.txt 2>&1
python3 concurrency_demo.py | tee evidence/concurrency_output.txt
```

## 1. Transactions in the clinic (ACID)

| Business operation | Why it must be one transaction |
|---|---|
| Complete consultation | Status → COMPLETED, diagnosis inserted, invoice raised. A completed visit with no invoice means lost revenue. An invoice without a diagnosis is a clinical-record gap. |
| Dispense prescription | Stock must be decremented for **every** item, and `dispensed` set, or nothing at all. |
| Take payment | Insert the payment and update the invoice status together. |

### Single-session results (`evidence/transactions_sql_output.txt`)

| Demo | What happened | ACID property |
|---|---|---|
| **T1 COMMIT** | `CALL complete_consultation(137871,'I10',45)` updated 3 tables. After COMMIT all three rows exist. | Atomicity, Durability |
| **T2 ROLLBACK (application rule)** | Completing the same appointment again raised `Appointment … is not in BOOKED state`. The transaction rolled back and the diagnosis count stayed at 1. | Atomicity, Consistency |
| **T3 ROLLBACK (CHECK constraint)** | The prescription asks for 5 Antivenom vials (stock 3) plus 28 Paracetamol. The UPDATE violated `stock_qty >= 0`, so the **whole** transaction was undone. **Paracetamol stock was not decremented either** (100000 before and after), and `dispensed` stayed `false`. | Atomicity, Consistency |
| **T4 SAVEPOINT** | Ordered FBC, then an invalid `XRAY` (FK error), then `ROLLBACK TO SAVEPOINT` and HBA1C. The valid orders were committed and only the failed step was discarded. Order IDs 35014 and 35016 are kept; 35015 was used up by the failed insert, because identity/sequence values are not transactional. | Partial rollback |
| **T5 Durability** | A brand-new session (`\c`) sees the committed status. The audit trigger row (BOOKED → COMPLETED) is there too. | Durability |

## 2. Concurrency anomalies and control (`evidence/concurrency_output.txt`)

### C1 Lost update: pharmacy stock (READ COMMITTED)
Two pharmacists read stock = 1000 and each writes back `value − n`.
**Result: 972 instead of 916.** Pharmacist B's 56 tablets disappeared from the records, so physical stock and recorded stock no longer match.

| Fix | Mechanism | Result |
|---|---|---|
| A. Atomic `SET stock_qty = stock_qty - n` | The row-level write lock makes the second UPDATE wait. PostgreSQL then **re-evaluates it against the newly committed row version** | 916 ✔ |
| B. `SELECT … FOR UPDATE` | Pessimistic locking. `pg_locks` captured while B was blocked shows A holding `ExclusiveLock` on its transaction ID, and B holding the tuple lock but waiting with `ShareLock granted=False` on A's transaction ID. B unblocked after 0.52 s and read A's committed value of 972. | 916 ✔ |
| C. `REPEATABLE READ` + retry | Optimistic. A's update fails with **SQLSTATE 40001** "could not serialize access due to concurrent update". The application retries, reads 944 and writes 916. | 916 ✔ |

**Choice for CarePoint:** Fix A for simple decrements, because it is the cheapest. Use Fix B when the application must check the value before deciding (for example "only dispense if stock ≥ quantity, otherwise order more"). Fix C suits low-contention workflows, but the application then needs retry logic.

### C2 Non-repeatable read
Finance reads an invoice twice in one transaction while reception adds a £15 test.
- **READ COMMITTED:** 45.00, then 60.00. Each *statement* gets a new snapshot. **Anomaly.**
- **REPEATABLE READ:** 45.00, then 45.00. One snapshot is used for the whole *transaction* (MVCC: the reader sees the older row version and never blocks the writer). **Prevented.**

### C3 Write skew: on-call rota (an anomaly REPEATABLE READ does *not* stop)
Rule: at least one cardiologist must be on call on 25 Dec. Doctors 2 and 10 both check "2 on call, so I can leave", then each updates **their own** row.
- **REPEATABLE READ:** both commit, leaving **0 doctors on call. Rule violated.** No row was written by both transactions, so no write–write conflict is detected.
- **SERIALIZABLE (SSI):** PostgreSQL tracks read/write dependencies. Dr 10 gets **40001** "could not serialize access due to read/write dependencies among transactions". 1 doctor stays on call ✔.

This is why safety-critical rules that span several rows need `SERIALIZABLE`, or an explicit lock on the rows they read.

### C4 Concurrent double-booking
Two receptionists insert the same 10:00 slot for Dr 5. Receptionist B's insert **blocked for 1.00 s** until A committed, then failed with `23P01 … exclusion constraint "no_doctor_double_booking"`. The GiST exclusion constraint from Portfolio 1 works as a **concurrency control mechanism**: it is enforced across uncommitted transactions, which an application-level "check, then insert" cannot guarantee.

### C5 Deadlock
A locks Amoxicillin and then wants Ibuprofen. B locks Ibuprofen and then wants Amoxicillin. After `deadlock_timeout` (500 ms) PostgreSQL's wait-for-graph detector aborted **B with 40P01**, and A completed.
**Fix:** acquire locks in a consistent global order (`SELECT … ORDER BY medication_id FOR UPDATE`). On re-running, both transactions committed with no deadlock.

## 3. Isolation levels summary (PostgreSQL behaviour, verified above)

| Level | Dirty read | Non-repeatable read | Phantom | Lost update | Write skew |
|---|---|---|---|---|---|
| Read Uncommitted (treated as RC in PG) | No | Possible | Possible | Possible (C1) | Possible |
| **Read Committed** (default) | No | **Possible (C2)** | Possible | **Possible (C1)** | Possible |
| **Repeatable Read** (snapshot isolation) | No | **Prevented (C2)** | Prevented in PG | **Detected → 40001 (C1-C)** | **Possible (C3)** |
| **Serializable** (SSI) | No | Prevented | Prevented | Prevented | **Prevented (C3)** |

## 4. Recommendations for CarePoint
1. Keep **READ COMMITTED** as the default, for throughput and to avoid retry storms at busy reception desks.
2. Use **atomic updates** or **`FOR UPDATE`** for stock and invoice balances.
3. Use **SERIALIZABLE** with an automatic **retry loop** (SQLSTATE 40001 / 40P01) for rota and bed-allocation rules that span several rows.
4. Push invariants into the DBMS (CHECK, EXCLUDE, FK) wherever possible. C4 and T3 show that the database enforces them correctly even under concurrency.
5. Keep transactions short and never wait for user input inside one, because long transactions hold locks and stop VACUUM from cleaning up old row versions.
