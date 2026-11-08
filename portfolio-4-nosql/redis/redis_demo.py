"""
Portfolio 4 – Key-value NoSQL (Redis 7) for CarePoint Clinic

Redis complements (does not replace) the PostgreSQL system of record. It handles the
high-frequency, short-lived, real-time data that a relational DB serves poorly:

  K1  Patient summary cache (Hash + TTL, cache-aside)       -> latency vs PostgreSQL
  K2  Waiting-room queue per doctor (Sorted Set by check-in time)
  K3  Free appointment slots for a doctor/day (Set, atomic SPOP/SREM)
  K4  Optimistic transaction on slot booking (WATCH / MULTI / EXEC)
  K5  Lab-result notifications (Stream + consumer group, at-least-once delivery)
  K6  Live "busiest doctors today" dashboard (Sorted Set ZINCRBY)
  K7  Login session tokens with automatic expiry (String + EX)

Usage: python3 redis_demo.py | tee ../evidence/redis_output.txt
"""
import json, os, statistics, threading, time
import psycopg2, redis

r = redis.Redis(host=os.getenv("REDIS_HOST", "localhost"), port=6379, decode_responses=True)
pg = psycopg2.connect(host=os.getenv("PGHOST", "localhost"), user=os.getenv("PGUSER", "postgres"),
                      password=os.getenv("PGPASSWORD", "postgres"), dbname=os.getenv("PGDATABASE", "carepoint"))
pg.autocommit = True
cur = pg.cursor()


def h(t):
    print("\n" + "=" * 90 + f"\n{t}\n" + "=" * 90)


r.flushdb()
print("Redis", r.info("server")["redis_version"], "| keys after FLUSHDB:", r.dbsize())

# ------------------------------------------------------------------------------------------
h("K1. Patient summary cache – Hash per patient, key = patient:{hospital_no}, TTL 15 min (cache-aside)")
SUMMARY_SQL = """
SELECT p.hospital_no, p.first_name || ' ' || p.last_name, p.date_of_birth::text, p.blood_group,
       COALESCE((SELECT string_agg(allergen || ' (' || severity || ')', ', ') FROM clinic.allergy a WHERE a.patient_id = p.patient_id), 'None'),
       (SELECT count(*) FROM clinic.appointment a WHERE a.patient_id = p.patient_id),
       (SELECT max(scheduled_start)::text FROM clinic.appointment a WHERE a.patient_id = p.patient_id AND status='COMPLETED'),
       (SELECT dx.icd10_code FROM clinic.appointment a JOIN clinic.diagnosis dx USING (appointment_id)
         WHERE a.patient_id = p.patient_id ORDER BY a.scheduled_start DESC LIMIT 1)
FROM clinic.patient p WHERE p.hospital_no = %s"""
FIELDS = ["hospital_no", "name", "dob", "blood_group", "allergies", "visits", "last_visit", "last_diagnosis"]


def get_summary(hno):
    key = f"patient:{hno}"
    cached = r.hgetall(key)
    if cached:
        return cached, "HIT"
    cur.execute(SUMMARY_SQL, (hno,))
    row = dict(zip(FIELDS, [str(v) for v in cur.fetchone()]))
    pipe = r.pipeline()
    pipe.hset(key, mapping=row)
    pipe.expire(key, 900)
    pipe.execute()
    return row, "MISS"


doc, status = get_summary("CP00012345")
print(f"1st call: {status} -> loaded from PostgreSQL and stored in Redis")
print(json.dumps(doc, indent=2))
doc, status = get_summary("CP00012345")
print(f"2nd call: {status};  TTL remaining = {r.ttl('patient:CP00012345')} s")

pg_t, rd_t = [], []
for i in range(200):
    hno = f"CP{(1000 + i):08d}"
    t = time.perf_counter(); cur.execute(SUMMARY_SQL, (hno,)); cur.fetchone(); pg_t.append((time.perf_counter() - t) * 1000)
    get_summary(hno)
for i in range(200):
    hno = f"CP{(1000 + i):08d}"
    t = time.perf_counter(); r.hgetall(f"patient:{hno}"); rd_t.append((time.perf_counter() - t) * 1000)
print(f"Latency over 200 patients – PostgreSQL query median {statistics.median(pg_t):.3f} ms | "
      f"Redis HGETALL median {statistics.median(rd_t):.3f} ms | speed-up {statistics.median(pg_t) / statistics.median(rd_t):.1f}x")
print("Invalidation on write: when an allergy is added in PostgreSQL the app runs DEL patient:{hno}")
r.delete("patient:CP00012345")
print("exists after DEL:", r.exists("patient:CP00012345"))

# ------------------------------------------------------------------------------------------
h("K2. Waiting-room queue – Sorted Set queue:doctor:{id}:{date}, score = check-in epoch")
q = "queue:doctor:17:2026-11-03"
base = 1793696400  # 2026-11-03 09:00 UTC
for hno, mins in [("CP00000077", 2), ("CP00004410", 0), ("CP00019001", 5), ("CP00000500", 1)]:
    r.zadd(q, {hno: base + mins * 60})
print("Queue (earliest first):", r.zrange(q, 0, -1, withscores=True))
print("Position of CP00019001:", r.zrank(q, "CP00019001") + 1, "of", r.zcard(q))
nxt = r.zpopmin(q)
print("Doctor calls next patient (ZPOPMIN, atomic):", nxt)
print("Remaining:", r.zrange(q, 0, -1))
r.zadd(q, {"CP00009999": base - 600})  # urgent: back-dated score jumps the queue
print("Urgent patient added with earlier score -> front of queue:", r.zrange(q, 0, 0))

# ------------------------------------------------------------------------------------------
h("K3. Free slots – Set slots:doctor:5:2027-02-01 ; booking = SREM (atomic, returns 1 only to the winner)")
sk = "slots:doctor:5:2027-02-01"
r.sadd(sk, *[f"{9 + i // 4:02d}:{(i % 4) * 15:02d}" for i in range(16)])
print("Free slots:", sorted(r.smembers(sk)))
results = {}


def try_book(who):
    results[who] = r.srem(sk, "10:00")


ts = [threading.Thread(target=try_book, args=(w,)) for w in ("recept_A", "recept_B", "online_portal")]
[t.start() for t in ts]; [t.join() for t in ts]
print("Three clients race for 10:00 ->", results, "(exactly one gets 1)")
print("10:00 still free?", r.sismember(sk, "10:00"), "| free count:", r.scard(sk))

# ------------------------------------------------------------------------------------------
h("K4. Optimistic transaction – WATCH / MULTI / EXEC (book slot + push to patient's upcoming list)")


def book(slot, patient, interfere=False):
    with r.pipeline() as p:
        while True:
            try:
                p.watch(sk)
                if not p.sismember(sk, slot):
                    p.unwatch(); return f"{patient}: slot {slot} no longer free"
                if interfere:
                    r.srem(sk, slot)  # another client books it between WATCH and EXEC
                    interfere = False
                    print("   (another client took", slot, "after WATCH)")
                p.multi()
                p.srem(sk, slot)
                p.rpush(f"upcoming:{patient}", f"2027-02-01 {slot} Dr5")
                p.execute()
                return f"{patient}: booked {slot}"
            except redis.WatchError:
                print(f"   WatchError for {patient} -> transaction discarded, retrying")


print(book("11:00", "CP00000001"))
print(book("11:15", "CP00000002", interfere=True))
print("upcoming:CP00000001 =", r.lrange("upcoming:CP00000001", 0, -1), "| upcoming:CP00000002 =", r.lrange("upcoming:CP00000002", 0, -1))

# ------------------------------------------------------------------------------------------
h("K5. Lab-result notifications – Stream lab:results + consumer group 'doctor-app'")
stream = "lab:results"
r.xgroup_create(stream, "doctor-app", id="0", mkstream=True)
cur.execute("""SELECT r.lab_order_id, o.test_code, r.result_value::text, r.flag, a.doctor_id, p.hospital_no
               FROM clinic.lab_result r JOIN clinic.lab_order o USING (lab_order_id)
               JOIN clinic.appointment a USING (appointment_id) JOIN clinic.patient p USING (patient_id)
               WHERE r.flag = 'H' ORDER BY r.resulted_at DESC LIMIT 4""")
for oid, test, val, flag, doc_id, hno in cur.fetchall():
    mid = r.xadd(stream, {"lab_order_id": oid, "test": test, "value": val, "flag": flag, "doctor_id": doc_id, "patient": hno})
    print("XADD", mid, test, val, flag, "for", hno)
msgs = r.xreadgroup("doctor-app", "tablet-1", {stream: ">"}, count=3)
ids = [m[0] for m in msgs[0][1]]
print("Consumer tablet-1 read", len(ids), "messages:", [m[1]["test"] + "=" + m[1]["value"] for m in msgs[0][1]])
r.xack(stream, "doctor-app", *ids[:2])
print("Acked 2; pending (unacknowledged) entries:", r.xpending(stream, "doctor-app")["pending"],
      "-> the 3rd would be redelivered if tablet-1 crashed (at-least-once)")

# ------------------------------------------------------------------------------------------
h("K6. Live dashboard – Sorted Set dash:consults:2026-10-30, ZINCRBY on each completed consult")
cur.execute("""SELECT d.last_name || ' (#' || d.doctor_id || ')' FROM clinic.appointment a JOIN clinic.doctor d USING (doctor_id)
               WHERE a.status='COMPLETED' AND a.scheduled_start >= '2026-10-30' AND a.scheduled_start < '2026-10-31'""")
for (docname,) in cur.fetchall():
    r.zincrby("dash:consults:2026-10-30", 1, docname)
print("Top 5 busiest doctors (ZREVRANGE):")
for name, score in r.zrevrange("dash:consults:2026-10-30", 0, 4, withscores=True):
    print(f"   {name:<22} {int(score)}")

# ------------------------------------------------------------------------------------------
h("K7. Session tokens – String with EX (auto-expiry, no clean-up job needed)")
r.set("session:9f2c1a", json.dumps({"user": "dr17@carepoint.example", "role": "doctor"}), ex=2)
print("GET immediately :", r.get("session:9f2c1a"))
time.sleep(2.2)
print("GET after 2.2 s :", r.get("session:9f2c1a"), "(expired)")

h("Keyspace summary")
for k in sorted(r.scan_iter("*")):
    if k.startswith("patient:CP0000"):
        continue
    print(f"   {k:<32} type={r.type(k)}")
print("   patient:* cache entries:", sum(1 for _ in r.scan_iter("patient:*")))
print("   used_memory_human:", r.info("memory")["used_memory_human"])
