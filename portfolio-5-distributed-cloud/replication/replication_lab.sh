#!/usr/bin/env bash
# =====================================================================
# Portfolio 5 – Distributed database lab for CarePoint Clinic
# Builds a 3-node PostgreSQL 16 topology on one machine (different ports):
#   node1  :5440  PRIMARY  (London site)
#   node2  :5441  HOT STANDBY via streaming replication (Manchester site)
# and demonstrates replication, read scaling, sync vs async commit
# (consistency vs availability), lag, and failover by promotion.
#
# Run as the postgres OS user:   sudo -u postgres bash replication_lab.sh 2>&1 | tee ../evidence/replication_output.txt
# Requires: PostgreSQL 16 binaries, an existing 'carepoint' DB on :5432 to copy data from.
# =====================================================================
set -uo pipefail
BIN=/usr/lib/postgresql/16/bin
LAB=${LAB:-/tmp/carepoint-lab}
P=5440; S=5441
psqlp() { psql -X -p "$P" -h /tmp -d carepoint "$@"; }
psqls() { psql -X -p "$S" -h /tmp -d carepoint "$@"; }
step()  { echo; echo "=================================================================================="; echo "$*"; echo "=================================================================================="; }

for port in $P $S; do $BIN/pg_ctl -D "$LAB/node_$port" stop -m immediate >/dev/null 2>&1 || true; done
rm -rf "$LAB"; mkdir -p "$LAB"

step "R1. Initialise PRIMARY (node1 :$P) with replication settings"
$BIN/initdb -D "$LAB/node_$P" -U postgres --auth=trust >/dev/null
cat >> "$LAB/node_$P/postgresql.conf" <<EOF
port = $P
unix_socket_directories = '/tmp'
listen_addresses = 'localhost'
wal_level = replica
max_wal_senders = 5
max_replication_slots = 5
wal_keep_size = 256MB
hot_standby = on
synchronous_commit = on
synchronous_standby_names = ''          # start ASYNCHRONOUS
cluster_name = 'node1_london'
EOF
echo "host replication replicator 127.0.0.1/32 trust" >> "$LAB/node_$P/pg_hba.conf"
$BIN/pg_ctl -D "$LAB/node_$P" -l "$LAB/node_$P.log" start -w >/dev/null && echo "primary started"
psql -X -p $P -h /tmp -d postgres -qc "CREATE ROLE replicator WITH REPLICATION LOGIN;" -c "CREATE DATABASE carepoint;"
echo "copying CarePoint data from :5432 (pg_dump | psql) ..."
PGPASSWORD=${SRC_PGPASSWORD:-postgres} pg_dump -h localhost -p 5432 -U postgres -d carepoint -n clinic | psqlp -q >/dev/null 2>&1
psqlp -Atc "SELECT 'appointments on primary: ' || count(*) FROM clinic.appointment"
psqlp -Atc "SELECT 'replication slot: ' || slot_name FROM pg_create_physical_replication_slot('node2_manchester')"

step "R2. Create HOT STANDBY (node2 :$S) with pg_basebackup -R (writes standby.signal + primary_conninfo)"
$BIN/pg_basebackup -h 127.0.0.1 -p $P -U replicator -D "$LAB/node_$S" -R -X stream -S node2_manchester --checkpoint=fast
sed -i "s/^port = $P/port = $S/; s/^cluster_name = .*/cluster_name = 'node2_manchester'/" "$LAB/node_$S/postgresql.conf"
echo "primary_conninfo in postgresql.auto.conf:"; grep primary_conninfo "$LAB/node_$S/postgresql.auto.conf" | sed 's/password=[^ ]*//'
ls "$LAB/node_$S/standby.signal" && $BIN/pg_ctl -D "$LAB/node_$S" -l "$LAB/node_$S.log" start -w >/dev/null && echo "standby started"
sleep 1

step "R3. Replication status – on PRIMARY (pg_stat_replication) and STANDBY (pg_stat_wal_receiver)"
psqlp -c "SELECT application_name, client_addr, state, sync_state, sent_lsn, replay_lsn FROM pg_stat_replication;"
psqls -c "SELECT status, sender_port, slot_name, received_tli FROM pg_stat_wal_receiver;"
psqls -Atc "SELECT 'standby pg_is_in_recovery() = ' || pg_is_in_recovery()"

step "R4. Data written on the PRIMARY appears on the STANDBY (read replica)"
psqlp -c "INSERT INTO clinic.patient(hospital_no, first_name, last_name, date_of_birth, sex, city)
          VALUES ('CP90000001','Replica','Test','1990-05-05','F','Manchester') RETURNING patient_id, hospital_no;"
sleep 0.5
echo "-- read on standby:"
psqls -c "SELECT patient_id, hospital_no, first_name, city FROM clinic.patient WHERE hospital_no='CP90000001';"

step "R5. The STANDBY is read-only – writes are rejected"
psqls -c "INSERT INTO clinic.patient(hospital_no, first_name, last_name, date_of_birth, sex) VALUES ('CP90000002','X','Y','1990-01-01','M');" 2>&1

step "R6. Read scaling – the Portfolio 2 analytical query (Q3) runs on the replica, offloading the primary"
psqls -c "\timing on" -c "SELECT dep.name, count(*) AS consultations FROM clinic.appointment a JOIN clinic.doctor d USING (doctor_id)
                          JOIN clinic.department dep USING (department_id) WHERE a.status='COMPLETED' GROUP BY dep.name ORDER BY 2 DESC LIMIT 3;"

step "R7. Replication lag under a write burst (ASYNC) – 20,000 appointment status updates"
psqlp -qc "UPDATE clinic.appointment SET reason = reason || ' ' WHERE appointment_id <= 20000;" &
for i in 1 2 3 4 5 6; do
  psqlp -Atc "SELECT 'lag sample $i: ' || COALESCE(pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)),'n/a') || ' behind, replay_lag=' || COALESCE(replay_lag::text,'0') FROM pg_stat_replication"
  sleep 0.15
done
wait
sleep 1
psqlp -Atc "SELECT 'after burst: ' || pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) || ' behind (caught up)' FROM pg_stat_replication"

step "R8. SYNCHRONOUS replication – commit waits for the standby (stronger consistency / durability)"
psqlp -qc "ALTER SYSTEM SET synchronous_standby_names = 'node2_manchester';" -c "SELECT pg_reload_conf();" >/dev/null
sleep 1
psqlp -c "SELECT application_name, sync_state FROM pg_stat_replication;"
echo "-- 200 single-row commits, ASYNC vs SYNC (each commit = 1 transaction):"
psqlp -qc "ALTER SYSTEM SET synchronous_standby_names = '';" -c "SELECT pg_reload_conf();" >/dev/null; sleep 0.5
t0=$(date +%s%N); for i in $(seq 1 200); do echo "UPDATE clinic.medication SET stock_qty = stock_qty WHERE medication_id = 1;"; done | psqlp -q; t1=$(date +%s%N)
echo "ASYNC: $(( (t1-t0)/1000000 )) ms"
psqlp -qc "ALTER SYSTEM SET synchronous_standby_names = 'node2_manchester';" -c "SELECT pg_reload_conf();" >/dev/null; sleep 0.5
t0=$(date +%s%N); for i in $(seq 1 200); do echo "UPDATE clinic.medication SET stock_qty = stock_qty WHERE medication_id = 1;"; done | psqlp -q; t1=$(date +%s%N)
echo "SYNC : $(( (t1-t0)/1000000 )) ms   (same machine; across real sites each commit also pays the network round-trip)"

step "R9. CAP in practice – SYNC mode with the standby DOWN: primary stays up but commits BLOCK (C over A)"
$BIN/pg_ctl -D "$LAB/node_$S" stop -m fast >/dev/null && echo "standby stopped (simulated network partition / site failure)"
psqlp -Atc "SELECT 'connected standbys: ' || count(*) FROM pg_stat_replication"
echo "-- a clinician saves a record (runs in background) ..."
psqlp -c "INSERT INTO clinic.icd10_code VALUES ('Z00.0','General adult medical examination');" > "$LAB/r9.txt" 2>&1 &
sleep 3
psqlp -Atc "SELECT '   after 3 s the session is still waiting: pid=' || pid || ' wait_event=' || wait_event || ' state=' || state FROM pg_stat_activity WHERE wait_event = 'SyncRep'"
echo "-- operator cancels the wait (statement_timeout cannot interrupt a sync-rep commit wait):"
psqlp -Atc "SELECT '   pg_cancel_backend -> ' || pg_cancel_backend(pid) FROM pg_stat_activity WHERE wait_event = 'SyncRep'" >/dev/null
wait
sed 's/^/   client saw: /' "$LAB/r9.txt"
echo "-- i.e. the row is committed LOCALLY on the primary but NOT confirmed on any replica – the client cannot be told it is safe"
echo "-- switching back to ASYNC restores availability (A over C – risk of losing the last commits on failover):"
psqlp -qc "ALTER SYSTEM SET synchronous_standby_names = '';" -c "SELECT pg_reload_conf();" >/dev/null; sleep 0.5
psqlp -c "INSERT INTO clinic.icd10_code VALUES ('Z00.1','Routine child health examination') RETURNING code;"
$BIN/pg_ctl -D "$LAB/node_$S" -l "$LAB/node_$S.log" start -w >/dev/null && echo "standby restarted – it reconnects and replays the WAL it missed (slot retained it):"
sleep 2
psqls -c "SELECT code, description FROM clinic.icd10_code WHERE code LIKE 'Z00%' ORDER BY code;"

step "R10. FAILOVER – primary site fails; promote the standby"
psqlp -Atc "SELECT 'last patient on primary before failure: ' || max(hospital_no) FROM clinic.patient"
$BIN/pg_ctl -D "$LAB/node_$P" stop -m immediate >/dev/null && echo "PRIMARY CRASHED (pg_ctl stop -m immediate)"
t0=$(date +%s%N)
psqls -Atc "SELECT 'pg_promote() -> ' || pg_promote(wait => true)"
t1=$(date +%s%N); echo "promotion took $(( (t1-t0)/1000000 )) ms"
psqls -Atc "SELECT 'node2 pg_is_in_recovery() = ' || pg_is_in_recovery() || '  (now a read-write PRIMARY)'"
psqls -c "INSERT INTO clinic.patient(hospital_no, first_name, last_name, date_of_birth, sex, city)
          VALUES ('CP90000003','After','Failover','1985-03-03','M','Manchester') RETURNING hospital_no;"
psqls -qc "CHECKPOINT"
psqls -Atc "SELECT 'timeline: ' || timeline_id || '  (was 1 – promotion starts a new WAL timeline so old and new histories cannot be confused)' FROM pg_control_checkpoint()"
echo "(Old node1 must NOT simply restart as primary – that would cause split-brain. It is rebuilt as a standby with pg_rewind/pg_basebackup.)"

step "Clean-up"
$BIN/pg_ctl -D "$LAB/node_$S" stop -m fast >/dev/null; echo "lab nodes stopped; data in $LAB"
