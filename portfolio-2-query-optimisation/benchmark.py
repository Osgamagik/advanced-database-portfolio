"""
Portfolio 2 benchmark: runs every query in queries.sql with EXPLAIN (ANALYZE, BUFFERS)
BEFORE and AFTER the indexes in indexes.sql, saves each plan to evidence/, and writes
a summary table (median of N runs, warm cache) to evidence/summary.md.

Usage:  python3 benchmark.py   (env: PGHOST, PGUSER, PGPASSWORD, PGDATABASE=carepoint)
"""
import os, re, statistics, pathlib
import psycopg2

RUNS = 5
HERE = pathlib.Path(__file__).parent
EVID = HERE / "evidence"
DSN = dict(host=os.getenv("PGHOST", "localhost"), user=os.getenv("PGUSER", "postgres"),
           password=os.getenv("PGPASSWORD", "postgres"), dbname=os.getenv("PGDATABASE", "carepoint"))

INDEX_NAMES = re.findall(r"CREATE INDEX IF NOT EXISTS (\w+)", (HERE / "indexes.sql").read_text())


def load_queries():
    text = (HERE / "queries.sql").read_text()
    parts = re.split(r"^-- name: (Q\d+) (.*)$", text, flags=re.M)
    return [(parts[i], parts[i + 1].strip(), parts[i + 2].strip().rstrip(";")) for i in range(1, len(parts), 3)]


def explain(cur, sql):
    cur.execute("EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) " + sql)
    plan = "\n".join(r[0] for r in cur.fetchall())
    ms = float(re.search(r"Execution Time: ([\d.]+) ms", plan).group(1))
    return plan, ms


def run_phase(cur, queries, phase):
    out = {}
    (EVID / phase).mkdir(parents=True, exist_ok=True)
    for qid, title, sql in queries:
        explain(cur, sql)                         # warm-up run (cache)
        times, plan = [], ""
        for _ in range(RUNS):
            plan, ms = explain(cur, sql)
            times.append(ms)
        med = statistics.median(times)
        top = re.search(r"(Seq Scan|Index Only Scan|Index Scan|Bitmap Heap Scan)", plan)
        out[qid] = (title, med, plan)
        (EVID / phase / f"{qid}.txt").write_text(f"-- {qid} {title}\n-- median of {RUNS}: {med:.3f} ms\n\n{sql};\n\n{plan}\n")
        print(f"[{phase}] {qid}: {med:9.3f} ms")
    return out


def main():
    conn = psycopg2.connect(**DSN)
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("SET max_parallel_workers_per_gather = 0")   # deterministic, single-core plans
    queries = load_queries()

    for ix in INDEX_NAMES:                                    # baseline = no optimisation indexes
        cur.execute(f"DROP INDEX IF EXISTS clinic.{ix}")
    cur.execute("ANALYZE")
    before = run_phase(cur, queries, "before")

    cur.execute((HERE / "indexes.sql").read_text())
    cur.execute("""SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid))
                   FROM pg_stat_user_indexes WHERE schemaname='clinic' AND indexrelname LIKE 'ix_%'
                   ORDER BY 1""")
    sizes = cur.fetchall()
    after = run_phase(cur, queries, "after")

    lines = ["| Query | Description | Before (ms) | After (ms) | Speed-up |", "|---|---|---:|---:|---:|"]
    for qid, title, _ in queries:
        b, a = before[qid][1], after[qid][1]
        lines.append(f"| {qid} | {title} | {b:.2f} | {a:.2f} | {b / a:.1f}× |")
    lines += ["", "| Index | Size |", "|---|---:|"] + [f"| {n} | {s} |" for n, s in sizes]
    (EVID / "summary.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
