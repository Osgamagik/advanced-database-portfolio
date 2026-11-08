# Portfolio 2 – Query Processing and Optimisation

**Case study:** CarePoint Clinic (see Portfolio 1). **DBMS:** PostgreSQL 16. The dataset holds about 150k appointments, 116k invoices and 107k payments.

## Files

| File | Purpose |
|---|---|
| `queries.sql` | 8 realistic workload queries (Q1–Q8) covering joins, CTEs, window functions, anti-joins and FILTER aggregates |
| `indexes.sql` | Optimisation indexes, each one tied to a query |
| `benchmark.py` | Drops the indexes, runs `EXPLAIN (ANALYZE, BUFFERS)` 5× per query, creates the indexes, re-runs, and writes the evidence |
| `extras.sql` | Further experiments E1–E6: sargability, selectivity, materialised view, query rewrite, index usage, write cost |
| `evidence/before/Qn.txt`, `evidence/after/Qn.txt` | Full execution plans |
| `evidence/summary.md` | Timing table and index sizes |
| `evidence/extras_output.txt` | Output of E1–E6 |

```bash
pip install psycopg2-binary
PGDATABASE=carepoint python3 benchmark.py
psql -d carepoint -f extras.sql > evidence/extras_output.txt
```
Method: warm cache, median of 5 runs, `max_parallel_workers_per_gather = 0` so that plans are single-threaded and comparable. Absolute times depend on the machine. The **plan shapes** are the main evidence.

## 1. How PostgreSQL processes a query (brief)
1. **Parse.** The SQL text is turned into a parse tree.
2. **Rewrite.** Views are expanded. For example, `v_appointment_detail` is replaced by its underlying joins.
3. **Plan/optimise.** The cost-based optimiser enumerates access paths (Seq Scan, Index Scan, Index Only Scan, Bitmap Scan), join methods (Nested Loop, Hash, Merge) and join orders. It estimates the cost of each using table statistics collected by `ANALYZE`: row counts, most-common values, histograms and correlation.
4. **Execute.** The chosen plan tree runs as an iterator pipeline. `EXPLAIN ANALYZE` shows *estimated* rows next to *actual* rows, which is how bad estimates can be detected.

## 2. Results

| Query | Purpose | Before (ms) | After (ms) | Speed-up | Plan change |
|---|---|---:|---:|---:|---|
| Q1 | Full patient history | 32.07 | 0.18 | **181×** | Seq Scan on appointment (150k rows) and prescription became Bitmap Index Scan on `ix_appointment_patient` and Index Scan on `ix_prescription_appointment` |
| Q2 | Doctor's daily schedule | 1.56 | 0.05 | **33×** | Index on `(doctor_id, scheduled_start)` with INCLUDE |
| Q3 | Top-3 diagnoses per department (CTE + `dense_rank`) | 94.11 | 81.57 | 1.2× | Still mostly full scans (reads about 60% of the data) |
| Q4 | Monthly revenue per department | 150.38 | 188.91 | ~1× | Index-only scan on payment, but the Hash Joins over 50k rows dominate (difference is noise) |
| Q5 | Unpaid invoices > 30 days | 52.37 | 0.17 | **315×** | Seq Scan on invoice became a tiny **partial index** (208 kB) read in order, with `LIMIT 50` stopping early |
| Q6 | Surname prefix search | 1.77 | 0.26 | **7×** | Seq Scan became **expression index** `lower(last_name) text_pattern_ops` |
| Q7 | High HbA1c not yet seen by Endocrinology | 31.23 | 4.67 | **7×** | Partial index on `flag='H'`; the NOT EXISTS anti-join now probes `ix_appointment_patient` instead of scanning 150k rows |
| Q8 | No-show rate per doctor | 32.62 | 28.91 | 1.1× | Aggregates about 100k rows, so an index can't avoid reading them |

### Index design rationale
- **FK indexes** (`appointment.patient_id`, `prescription.appointment_id`, `lab_order.appointment_id`, `payment.invoice_id`). PostgreSQL indexes the *referenced* PK but not the *referencing* FK column, so every join from parent to child scanned the whole child table. This caused the biggest single gain (Q1).
- **Composite column order** `(doctor_id, scheduled_start)`. The equality column comes first and the range column second, so one contiguous index range covers exactly the doctor's day. `INCLUDE (status, patient_id)` makes it a **covering** index for Q2 and Q8.
- **Partial indexes** (`WHERE status='UNPAID'`, `WHERE flag='H'`). These index only the rows the query cares about, so they are 10–30× smaller than a full index and cheaper to maintain.
- **Expression index** on `lower(last_name)`. A plain index on `last_name` cannot serve `lower(last_name) LIKE 'oke%'`. `text_pattern_ops` is needed for `LIKE` prefix matching under a non-C collation.
- **Redundant index removed.** I first added `diagnosis(appointment_id)`, then noticed in the plans that the planner always used the existing `UNIQUE(appointment_id, icd10_code)` index, because its leading column is the same. I removed the extra index, since it would only slow down writes.

## 3. Further experiments (`evidence/extras_output.txt`)

| # | Experiment | Finding |
|---|---|---|
| E1 | `(scheduled_start AT TIME ZONE 'UTC')::date = '2026-11-03'` vs a half-open range | Non-sargable: the index can only use `doctor_id`, then **filters 2,477 rows** (3.67 ms). The range rewrite uses both index columns (0.07 ms), about **55× faster**. Rule: never wrap an indexed column in a function. |
| E2 | Selectivity of `status` (77% COMPLETED, 7% NO_SHOW) | For COMPLETED the planner chooses a **Seq Scan** even though an index exists, because random I/O on 77% of rows costs more than reading sequentially. For NO_SHOW it chooses a **Bitmap Index Scan**. For `count(*)` the narrow index is used as an **Index Only Scan** thanks to the visibility map. Indexes help only when the predicate is selective or the index covers the query. |
| E3 | Materialised view for Q4 | Reading `mv_monthly_department_revenue` takes **0.20 ms vs ~150 ms** (about 750×). The cost moves to a nightly `REFRESH MATERIALIZED VIEW CONCURRENTLY` (~156 ms, and it doesn't block readers because of the unique index). Trade-off: figures are up to 24 h stale, which is acceptable for a management dashboard but not for the cashier. |
| E4 | Q3 rewritten to aggregate before joining department | No improvement (89 ms vs 82 ms). The plan showed the optimiser was **already** aggregating before the department join. This is a useful negative result: the planner often finds the rewrite itself, so it is better to measure before hand-tuning. |
| E5 | `pg_stat_user_indexes` | Shows scan counts for each index, so unused indexes can be identified and dropped. |
| E6 | Insert 5,000 appointments with vs without the 3 extra appointment indexes | 336 ms vs 312 ms, about **8% write overhead**. Most of the remaining insert cost comes from the GiST exclusion constraint and FK checks. This overhead is acceptable for a read-heavy clinic workload. |

## 4. Performance analysis (summary)
- The clinic's workload is **OLTP-dominated**: point lookups by patient, doctor or day (Q1, Q2, Q5, Q6, Q7). B-tree indexes reduced these from tens of milliseconds to well under 1 ms (7×–315×). This matters because these queries run thousands of times a day at reception.
- **Analytical** queries (Q3, Q4, Q8) read a large share of the table. No index fixes that, because the optimiser correctly prefers sequential scans and hash joins. The right tools are **pre-aggregation** (a materialised view, E3), running reports on a **read replica** (Portfolio 5), or partitioning by time.
- Indexes are not free. 10 extra indexes add about 23 MB and roughly 8% insert cost (E6), so each one has to be justified by a query, and redundant ones should be removed.
- `ANALYZE` statistics drive every decision above. Estimated and actual rows match closely in the saved plans (for example, Q4 estimated 49,338 payment rows against an actual 49,468), which is why the planner chose correctly.
