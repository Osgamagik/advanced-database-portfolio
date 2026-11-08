# AI Use Declaration

| | |
|---|---|
| **AI tool used** | Claude (Anthropic), via the Claude app |
| **What it was used for** | Generating the database schema, seed-data generator, SQL queries, test scripts (Python and Bash), README explanations and diagrams for all five portfolio activities, based on the chosen case study |
| **How the output was reviewed and verified** | I re-ran the SQL scripts on my own PostgreSQL installation and checked that the outputs matched. I wrote the individual reflection myself. |

Issues found and fixed during development (recorded in the READMEs as evidence of testing):
1. The exclusion constraint originally used `timestamptz + interval`, which is not IMMUTABLE. The design was changed to store `scheduled_end` (Portfolio 1 README §5).
2. Lab results were initially generated with an identical value per test type, because PostgreSQL evaluated `random()` in a `LATERAL` subquery once. This was detected when query Q7 returned no rows, and the generator was fixed (seed_data.sql comment).
3. A redundant index on `diagnosis(appointment_id)` was identified from execution plans and removed (Portfolio 2 README).
4. The first selectivity experiment (E2) gave an unexpected Index Only Scan. The cause (visibility map plus a narrow index) was investigated and the experiment was extended (E2c).
