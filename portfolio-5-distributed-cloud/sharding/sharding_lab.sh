#!/usr/bin/env bash
# =====================================================================
# Portfolio 5 – Horizontal sharding of appointments (CarePoint Clinic)
# 3 PostgreSQL 16 nodes:
#   coord   :5450  coordinator / router – holds the partitioned parent table
#   shard1  :5451  stores hash partitions 0 and 1
#   shard2  :5452  stores hash partitions 2 and 3
# Sharding key: patient_id  (HASH, modulus 4) -> all of one patient's appointments
# live on the same shard, so the commonest query (patient history) hits ONE node.
# Uses declarative partitioning + postgres_fdw foreign-table partitions.
#
# Run as postgres:  sudo -u postgres bash sharding_lab.sh 2>&1 | tee ../evidence/sharding_output.txt
# =====================================================================
set -uo pipefail
BIN=/usr/lib/postgresql/16/bin
LAB=${LAB:-/tmp/carepoint-shard-lab}
step() { echo; echo "=================================================================================="; echo "$*"; echo "=================================================================================="; }
q()    { local port=$1; shift; psql -X -h /tmp -p "$port" -d carepoint "$@"; }

for port in 5450 5451 5452; do $BIN/pg_ctl -D "$LAB/n$port" stop -m immediate >/dev/null 2>&1 || true; done
rm -rf "$LAB"; mkdir -p "$LAB"

step "S1. Start coordinator + 2 shard nodes"
for port in 5450 5451 5452; do
  $BIN/initdb -D "$LAB/n$port" -U postgres --auth=trust >/dev/null
  printf "port = %s\nunix_socket_directories = '/tmp'\nlisten_addresses = 'localhost'\n" "$port" >> "$LAB/n$port/postgresql.conf"
  $BIN/pg_ctl -D "$LAB/n$port" -l "$LAB/n$port.log" start -w >/dev/null && echo "node :$port up"
  psql -X -h /tmp -p "$port" -d postgres -qc "CREATE DATABASE carepoint"
done

step "S2. Create the physical partitions on each shard"
for spec in "5451 0" "5451 1" "5452 2" "5452 3"; do
  set -- $spec
  q "$1" -qc "CREATE TABLE IF NOT EXISTS appointment_p$2 (
      appointment_id BIGINT PRIMARY KEY, patient_id INT NOT NULL, doctor_id INT NOT NULL,
      scheduled_start TIMESTAMPTZ NOT NULL, scheduled_end TIMESTAMPTZ NOT NULL,
      status VARCHAR(10) NOT NULL, reason VARCHAR(200));
    CREATE INDEX IF NOT EXISTS ix_p$2_patient ON appointment_p$2(patient_id, scheduled_start);"
  echo "shard :$1 -> appointment_p$2"
done

step "S3. Coordinator: partitioned parent table; each partition is a FOREIGN TABLE on a shard"
q 5450 -q <<'SQL'
CREATE EXTENSION postgres_fdw;
CREATE SERVER shard1 FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host 'localhost', port '5451', dbname 'carepoint', async_capable 'true');
CREATE SERVER shard2 FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host 'localhost', port '5452', dbname 'carepoint', async_capable 'true');
CREATE USER MAPPING FOR postgres SERVER shard1 OPTIONS (user 'postgres');
CREATE USER MAPPING FOR postgres SERVER shard2 OPTIONS (user 'postgres');

CREATE TABLE appointment (
    appointment_id BIGINT NOT NULL, patient_id INT NOT NULL, doctor_id INT NOT NULL,
    scheduled_start TIMESTAMPTZ NOT NULL, scheduled_end TIMESTAMPTZ NOT NULL,
    status VARCHAR(10) NOT NULL, reason VARCHAR(200)
) PARTITION BY HASH (patient_id);

CREATE FOREIGN TABLE appointment_p0 PARTITION OF appointment FOR VALUES WITH (MODULUS 4, REMAINDER 0) SERVER shard1;
CREATE FOREIGN TABLE appointment_p1 PARTITION OF appointment FOR VALUES WITH (MODULUS 4, REMAINDER 1) SERVER shard1;
CREATE FOREIGN TABLE appointment_p2 PARTITION OF appointment FOR VALUES WITH (MODULUS 4, REMAINDER 2) SERVER shard2;
CREATE FOREIGN TABLE appointment_p3 PARTITION OF appointment FOR VALUES WITH (MODULUS 4, REMAINDER 3) SERVER shard2;
SQL
q 5450 -c "\d+ appointment" | sed -n '/Partition key/,/Number of partitions/p'

step "S4. Load 150k appointments through the coordinator (rows are ROUTED to shards by hash(patient_id))"
PGPASSWORD=${SRC_PGPASSWORD:-postgres} psql -X -h localhost -p 5432 -U postgres -d carepoint -qc \
  "\copy (SELECT appointment_id, patient_id, doctor_id, scheduled_start, scheduled_end, status, reason FROM clinic.appointment) TO '$LAB/appts.csv' CSV"
time q 5450 -qc "\copy appointment FROM '$LAB/appts.csv' CSV"
for port in 5451 5452; do q "$port" -qc "ANALYZE"; done
echo "-- rows per node (queried directly on each shard):"
q 5451 -Atc "SELECT 'shard1 :5451  p0=' || (SELECT count(*) FROM appointment_p0) || '  p1=' || (SELECT count(*) FROM appointment_p1)"
q 5452 -Atc "SELECT 'shard2 :5452  p2=' || (SELECT count(*) FROM appointment_p2) || '  p3=' || (SELECT count(*) FROM appointment_p3)"
q 5450 -Atc "SELECT 'coordinator total = ' || count(*) FROM appointment"

step "S5. Shard-local query: one patient's history -> partition PRUNING, only ONE shard is contacted"
q 5450 -c "EXPLAIN (VERBOSE, COSTS OFF) SELECT * FROM appointment WHERE patient_id = 12345 ORDER BY scheduled_start;"
q 5450 -c "SELECT appointment_id, scheduled_start, status FROM appointment WHERE patient_id = 12345 ORDER BY scheduled_start LIMIT 3;"

step "S6. Cross-shard (scatter-gather) query: appointments by status -> all 4 partitions on both shards, partial aggregates merged on the coordinator"
q 5450 -qc "SET enable_partitionwise_aggregate = on" -c "EXPLAIN (VERBOSE, COSTS OFF)
  SELECT status, count(*) FROM appointment GROUP BY status;"
q 5450 -c "SET enable_partitionwise_aggregate = on" -c "\timing on" -c "SELECT status, count(*) FROM appointment GROUP BY status ORDER BY 2 DESC;"

step "S7. Partial failure: shard2 goes down"
$BIN/pg_ctl -D "$LAB/n5452" stop -m immediate >/dev/null && echo "shard2 :5452 STOPPED"
echo "-- patient 12345 (hash remainder 0 -> shard1, see S5) is still served (plan-time pruning: shard2 never contacted):"
q 5450 -Atc "SELECT 'patient 12345: ' || count(*) || ' appointments' FROM appointment WHERE patient_id = 12345" 2>&1
echo "-- a global query fails (needs every shard):"
q 5450 -c "SELECT count(*) FROM appointment;" 2>&1 | head -3
$BIN/pg_ctl -D "$LAB/n5452" -l "$LAB/n5452.log" start -w >/dev/null && echo "shard2 restarted"
q 5450 -Atc "SELECT 'global count after recovery = ' || count(*) FROM appointment"

step "Clean-up"
for port in 5450 5451 5452; do $BIN/pg_ctl -D "$LAB/n$port" stop -m fast >/dev/null; done; echo "stopped"
