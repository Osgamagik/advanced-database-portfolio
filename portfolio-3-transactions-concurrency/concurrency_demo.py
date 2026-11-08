"""
Portfolio 3 – Concurrency anomalies and control mechanisms (CarePoint Clinic)

Two (or more) real PostgreSQL sessions are interleaved deterministically with
threading.Event so that each anomaly is reproducible on every run.

  C1  Lost update on medication stock         (READ COMMITTED, read-modify-write)
      fix A  atomic UPDATE ... SET x = x - n
      fix B  pessimistic lock  SELECT ... FOR UPDATE   (+ pg_locks evidence)
      fix C  REPEATABLE READ -> serialization error + retry
  C2  Non-repeatable read                      READ COMMITTED vs REPEATABLE READ
  C3  Write skew on the on-call rota          REPEATABLE READ (anomaly) vs SERIALIZABLE (prevented)
  C4  Concurrent double-booking               blocked by the EXCLUDE constraint
  C5  Deadlock between two pharmacists        detection + fix by consistent lock ordering

Usage:  python3 concurrency_demo.py | tee evidence/concurrency_output.txt
"""
import os, threading, time
import psycopg2
from psycopg2 import errors
from psycopg2.extensions import (ISOLATION_LEVEL_READ_COMMITTED as RC,
                                 ISOLATION_LEVEL_REPEATABLE_READ as RR,
                                 ISOLATION_LEVEL_SERIALIZABLE as SER)

DSN = dict(host=os.getenv("PGHOST", "localhost"), user=os.getenv("PGUSER", "postgres"),
           password=os.getenv("PGPASSWORD", "postgres"), dbname=os.getenv("PGDATABASE", "carepoint"),
           options="-c search_path=clinic -c lock_timeout=10s -c deadlock_timeout=500ms")
T0 = time.time()
LOG_LOCK = threading.Lock()


def log(who, msg):
    with LOG_LOCK:
        print(f"  [{time.time() - T0:6.2f}s] {who:<8} {msg}", flush=True)


def conn(level=RC, name="app"):
    c = psycopg2.connect(application_name=name, **DSN)
    c.set_isolation_level(level)
    return c


def admin(sql, args=None, fetch=True):
    with psycopg2.connect(**DSN) as c, c.cursor() as cur:
        cur.execute(sql, args)
        return cur.fetchall() if fetch and cur.description else None


def header(t):
    print("\n" + "=" * 100 + f"\n{t}\n" + "=" * 100)


def stock(med="Paracetamol"):
    return admin("SELECT stock_qty FROM medication WHERE name=%s", (med,))[0][0]


def set_stock(qty, med="Paracetamol"):
    admin("UPDATE medication SET stock_qty=%s WHERE name=%s", (qty, med), fetch=False)


# ---------------------------------------------------------------------------------------------
def c1_lost_update():
    header("C1. LOST UPDATE – two pharmacists dispense Paracetamol at the same time (READ COMMITTED)")
    set_stock(1000)
    log("setup", f"stock = {stock()}; pharmacist A dispenses 28, pharmacist B dispenses 56 -> expected 916")
    a_read, b_wrote = threading.Event(), threading.Event()

    def pharm_a():
        c = conn(RC, "pharm_A"); cur = c.cursor()
        cur.execute("SELECT stock_qty FROM medication WHERE name='Paracetamol'"); s = cur.fetchone()[0]
        log("A", f"reads stock = {s}")
        a_read.set(); b_wrote.wait()
        cur.execute("UPDATE medication SET stock_qty=%s WHERE name='Paracetamol'", (s - 28,))
        c.commit(); log("A", f"writes {s} - 28 = {s - 28} and COMMITs")

    def pharm_b():
        a_read.wait()
        c = conn(RC, "pharm_B"); cur = c.cursor()
        cur.execute("SELECT stock_qty FROM medication WHERE name='Paracetamol'"); s = cur.fetchone()[0]
        log("B", f"reads stock = {s}")
        cur.execute("UPDATE medication SET stock_qty=%s WHERE name='Paracetamol'", (s - 56,))
        c.commit(); log("B", f"writes {s} - 56 = {s - 56} and COMMITs")
        b_wrote.set()

    run(pharm_a, pharm_b)
    log("result", f"final stock = {stock()}  (expected 916) -> B's update was LOST: 56 tablets unaccounted for")

    # ---- Fix A: atomic update ------------------------------------------------------------------
    print("\n  --- Fix A: let the DBMS do read-modify-write atomically: UPDATE ... SET stock_qty = stock_qty - n")
    set_stock(1000)
    go = threading.Barrier(2)

    def atomic(n, who):
        c = conn(RC, who); cur = c.cursor(); go.wait()
        cur.execute("UPDATE medication SET stock_qty = stock_qty - %s WHERE name='Paracetamol' RETURNING stock_qty", (n,))
        log(who, f"stock_qty - {n} -> {cur.fetchone()[0]}"); c.commit()
    run(lambda: atomic(28, "A"), lambda: atomic(56, "B"))
    log("result", f"final stock = {stock()}  (expected 916) -> correct; the 2nd UPDATE waited for the row lock and re-read the row")

    # ---- Fix B: SELECT ... FOR UPDATE ----------------------------------------------------------
    print("\n  --- Fix B: pessimistic locking – SELECT ... FOR UPDATE (B must wait for A)")
    set_stock(1000)
    a_locked, b_waiting = threading.Event(), threading.Event()

    def pharm_a_lock():
        c = conn(RC, "pharm_A"); cur = c.cursor()
        cur.execute("SELECT stock_qty FROM medication WHERE name='Paracetamol' FOR UPDATE"); s = cur.fetchone()[0]
        log("A", f"SELECT ... FOR UPDATE -> {s} (row now locked)")
        a_locked.set(); b_waiting.wait(); time.sleep(0.5)
        rows = admin("""SELECT a.application_name, l.mode, l.granted
                        FROM pg_locks l JOIN pg_stat_activity a USING (pid)
                        WHERE a.application_name LIKE 'pharm_%' AND l.locktype IN ('transactionid','tuple')
                        ORDER BY a.application_name, l.granted DESC""")
        log("monitor", "pg_locks while B is blocked:")
        for r in rows:
            log("", f"    {r[0]:<8} {r[1]:<14} granted={r[2]}")
        cur.execute("UPDATE medication SET stock_qty=%s WHERE name='Paracetamol'", (s - 28,))
        c.commit(); log("A", f"writes {s - 28}, COMMIT (lock released)")

    def pharm_b_lock():
        a_locked.wait()
        c = conn(RC, "pharm_B"); cur = c.cursor()
        log("B", "SELECT ... FOR UPDATE -> blocks ...")
        b_waiting.set()
        t = time.time()
        cur.execute("SELECT stock_qty FROM medication WHERE name='Paracetamol' FOR UPDATE"); s = cur.fetchone()[0]
        log("B", f"... unblocked after {time.time() - t:.2f}s, reads {s} (A's committed value)")
        cur.execute("UPDATE medication SET stock_qty=%s WHERE name='Paracetamol'", (s - 56,))
        c.commit(); log("B", f"writes {s - 56}, COMMIT")
    run(pharm_a_lock, pharm_b_lock)
    log("result", f"final stock = {stock()}  (expected 916) -> correct")

    # ---- Fix C: REPEATABLE READ (optimistic) + retry -------------------------------------------
    print("\n  --- Fix C: optimistic – REPEATABLE READ; the second writer gets a serialization failure and RETRIES")
    set_stock(1000)
    a_read, b_done = threading.Event(), threading.Event()

    def pharm_a_rr():
        attempt = 0
        while True:
            attempt += 1
            c = conn(RR, "pharm_A"); cur = c.cursor()
            try:
                cur.execute("SELECT stock_qty FROM medication WHERE name='Paracetamol'"); s = cur.fetchone()[0]
                log("A", f"attempt {attempt}: reads {s}")
                if attempt == 1:
                    a_read.set(); b_done.wait()
                cur.execute("UPDATE medication SET stock_qty=%s WHERE name='Paracetamol'", (s - 28,))
                c.commit(); log("A", f"attempt {attempt}: writes {s - 28}, COMMIT"); return
            except errors.SerializationFailure as e:
                c.rollback(); log("A", f"attempt {attempt}: ERROR {e.pgcode} {str(e).splitlines()[0]} -> ROLLBACK and retry")

    def pharm_b_rr():
        a_read.wait()
        c = conn(RR, "pharm_B"); cur = c.cursor()
        cur.execute("SELECT stock_qty FROM medication WHERE name='Paracetamol'"); s = cur.fetchone()[0]
        cur.execute("UPDATE medication SET stock_qty=%s WHERE name='Paracetamol'", (s - 56,))
        c.commit(); log("B", f"reads {s}, writes {s - 56}, COMMIT"); b_done.set()
    run(pharm_a_rr, pharm_b_rr)
    log("result", f"final stock = {stock()}  (expected 916) -> correct")
    set_stock(100000)


# ---------------------------------------------------------------------------------------------
def c2_non_repeatable_read():
    for level, name in ((RC, "READ COMMITTED"), (RR, "REPEATABLE READ")):
        header(f"C2. NON-REPEATABLE READ – finance totals an invoice twice while reception edits it ({name})")
        inv = admin("SELECT min(invoice_id) FROM invoice")[0][0]
        admin("UPDATE invoice SET total_amount=45 WHERE invoice_id=%s", (inv,), fetch=False)
        first, changed = threading.Event(), threading.Event()
        res = {}

        def finance():
            c = conn(level, "finance"); cur = c.cursor()
            cur.execute("SELECT total_amount FROM invoice WHERE invoice_id=%s", (inv,)); res[1] = cur.fetchone()[0]
            log("finance", f"read #1 total = {res[1]}"); first.set(); changed.wait()
            cur.execute("SELECT total_amount FROM invoice WHERE invoice_id=%s", (inv,)); res[2] = cur.fetchone()[0]
            log("finance", f"read #2 total = {res[2]}  (same transaction)"); c.commit()

        def reception():
            first.wait(); c = conn(RC, "recept"); cur = c.cursor()
            cur.execute("UPDATE invoice SET total_amount = 60 WHERE invoice_id=%s", (inv,)); c.commit()
            log("recept", "adds a £15 lab test -> total 60, COMMIT"); changed.set()
        run(finance, reception)
        verdict = "ANOMALY: value changed inside one transaction" if res[1] != res[2] else "PREVENTED: snapshot taken at first read is stable"
        log("result", verdict)


# ---------------------------------------------------------------------------------------------
def c3_write_skew():
    admin("""CREATE TABLE IF NOT EXISTS on_call_rota(
               doctor_id INT REFERENCES doctor(doctor_id), shift_date DATE, on_call BOOLEAN NOT NULL,
               PRIMARY KEY (doctor_id, shift_date))""", fetch=False)
    rule = "Business rule: at least ONE cardiologist must stay on call for 2026-12-25"
    for level, name in ((RR, "REPEATABLE READ"), (SER, "SERIALIZABLE")):
        header(f"C3. WRITE SKEW – two cardiologists both ask to come off call ({name})")
        admin("DELETE FROM on_call_rota", fetch=False)
        admin("INSERT INTO on_call_rota VALUES (2,'2026-12-25',TRUE),(10,'2026-12-25',TRUE)", fetch=False)
        log("setup", rule + "; doctors 2 and 10 are on call")
        both_checked = threading.Barrier(2)

        def go_off(doc):
            c = conn(level, f"dr_{doc}"); cur = c.cursor()
            try:
                cur.execute("SELECT count(*) FROM on_call_rota WHERE shift_date='2026-12-25' AND on_call")
                n = cur.fetchone()[0]; log(f"dr_{doc}", f"sees {n} on call -> OK to leave")
                both_checked.wait()
                if n >= 2:
                    cur.execute("UPDATE on_call_rota SET on_call=FALSE WHERE doctor_id=%s AND shift_date='2026-12-25'", (doc,))
                time.sleep(0.2 if doc == 2 else 0.6)
                c.commit(); log(f"dr_{doc}", "COMMIT ok")
            except errors.SerializationFailure as e:
                c.rollback(); log(f"dr_{doc}", f"ERROR {e.pgcode}: {str(e).splitlines()[0]}")
        run(lambda: go_off(2), lambda: go_off(10))
        n = admin("SELECT count(*) FROM on_call_rota WHERE on_call")[0][0]
        log("result", f"doctors on call = {n} -> " + ("RULE VIOLATED (write skew)" if n == 0 else "rule preserved (SSI aborted one transaction)"))
    admin("DROP TABLE on_call_rota", fetch=False)


# ---------------------------------------------------------------------------------------------
def c4_double_booking():
    header("C4. CONCURRENT DOUBLE-BOOKING – two receptionists book Dr 5 at 2027-02-01 10:00 simultaneously")
    admin("DELETE FROM appointment WHERE doctor_id=5 AND scheduled_start >= '2027-02-01' AND scheduled_start < '2027-02-02'", fetch=False)
    a_inserted = threading.Event()

    def recept(who, patient, wait_first):
        c = conn(RC, who); cur = c.cursor()
        if wait_first:
            a_inserted.wait()
        try:
            t = time.time()
            cur.execute("""INSERT INTO appointment(patient_id, doctor_id, scheduled_start, scheduled_end)
                           VALUES (%s, 5, '2027-02-01 10:00', '2027-02-01 10:15') RETURNING appointment_id""", (patient,))
            log(who, f"INSERT ok (appointment {cur.fetchone()[0]}) after {time.time() - t:.2f}s – not yet committed")
            if not wait_first:
                a_inserted.set(); time.sleep(1.0)
            c.commit(); log(who, "COMMIT")
        except errors.ExclusionViolation as e:
            c.rollback(); log(who, f"blocked {time.time() - t:.2f}s, then ERROR {e.pgcode}: {str(e).splitlines()[0]}")
    run(lambda: recept("recept_A", 101, False), lambda: recept("recept_B", 202, True))
    n = admin("SELECT count(*) FROM appointment WHERE doctor_id=5 AND scheduled_start='2027-02-01 10:00'")[0][0]
    log("result", f"appointments in that slot = {n} -> the EXCLUDE constraint serialised the two inserts (B waited for A's outcome)")
    admin("DELETE FROM appointment WHERE doctor_id=5 AND scheduled_start='2027-02-01 10:00'", fetch=False)


# ---------------------------------------------------------------------------------------------
def c5_deadlock():
    header("C5. DEADLOCK – A updates Amoxicillin then Ibuprofen; B updates Ibuprofen then Amoxicillin")
    first_locks = threading.Barrier(2)

    def pharm(who, first, second):
        c = conn(RC, who); cur = c.cursor()
        try:
            cur.execute("UPDATE medication SET stock_qty = stock_qty - 1 WHERE name=%s", (first,))
            log(who, f"locked {first}"); first_locks.wait()
            log(who, f"requests {second} ...")
            cur.execute("UPDATE medication SET stock_qty = stock_qty - 1 WHERE name=%s", (second,))
            c.commit(); log(who, f"locked {second}, COMMIT")
        except errors.DeadlockDetected as e:
            c.rollback(); log(who, f"ERROR {e.pgcode} deadlock detected -> chosen as VICTIM, ROLLBACK")
    run(lambda: pharm("A", "Amoxicillin", "Ibuprofen"), lambda: pharm("B", "Ibuprofen", "Amoxicillin"))

    print("\n  --- Fix: every transaction locks rows in the SAME order (ORDER BY medication_id ... FOR UPDATE)")
    go = threading.Barrier(2)

    def pharm_ordered(who, meds):
        c = conn(RC, who); cur = c.cursor(); go.wait()
        cur.execute("SELECT medication_id FROM medication WHERE name = ANY(%s) ORDER BY medication_id FOR UPDATE", (meds,))
        cur.execute("UPDATE medication SET stock_qty = stock_qty - 1 WHERE name = ANY(%s)", (meds,))
        c.commit(); log(who, "both rows updated, COMMIT (no deadlock)")
    run(lambda: pharm_ordered("A", ["Amoxicillin", "Ibuprofen"]), lambda: pharm_ordered("B", ["Ibuprofen", "Amoxicillin"]))


def run(*fns):
    ts = [threading.Thread(target=f) for f in fns]
    [t.start() for t in ts]; [t.join() for t in ts]


if __name__ == "__main__":
    print(admin("SELECT version()")[0][0])
    c1_lost_update()
    c2_non_repeatable_read()
    c3_write_skew()
    c4_double_booking()
    c5_deadlock()
    print("\nAll scenarios complete.")
