| Query | Description | Before (ms) | After (ms) | Speed-up |
|---|---|---:|---:|---:|
| Q1 | Full clinical history of one patient (reception / doctor screen) | 32.07 | 0.18 | 181.2× |
| Q2 | A doctor's schedule for one day (most frequent query in the clinic) | 1.56 | 0.05 | 33.1× |
| Q3 | Top-3 diagnoses per department in the last 12 months (CTE + window function) | 94.11 | 81.57 | 1.2× |
| Q4 | Monthly revenue collected per department for 2026 | 150.38 | 188.91 | 0.8× |
| Q5 | Outstanding (unpaid) invoices older than 30 days – finance chase list | 52.37 | 0.17 | 315.5× |
| Q6 | Case-insensitive patient search by surname prefix (reception search box) | 1.77 | 0.26 | 6.9× |
| Q7 | Patients with an abnormal (high) HbA1c who have NOT been seen in Endocrinology since | 31.23 | 4.67 | 6.7× |
| Q8 | No-show rate per doctor in 2026 (aggregate + FILTER) | 32.62 | 28.91 | 1.1× |

| Index | Size |
|---|---:|
| ix_appointment_doctor_start | 7312 kB |
| ix_appointment_patient | 4656 kB |
| ix_appointment_start | 1424 kB |
| ix_invoice_unpaid | 208 kB |
| ix_lab_order_appointment | 784 kB |
| ix_lab_result_high_recent | 160 kB |
| ix_patient_lower_lastname | 608 kB |
| ix_payment_invoice | 2384 kB |
| ix_payment_paid_at | 4272 kB |
| ix_prescription_appointment | 1544 kB |
