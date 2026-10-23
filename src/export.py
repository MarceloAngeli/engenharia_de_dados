import os
import shutil
import statistics
import time
import duckdb

DB_PATH = (
    "./../sql/olist.duckdb"
)
# Everything is written to <architecture>/data/curated/
CURATED_DIR = (
    "./../architecture/data/curated"
)

FACT = "fact_order_items"
# 'YYYY-MM', derived from the fact column order_purchase_timestamp.
# (Partitioning by the raw timestamp would create one folder per distinct
# second; the month keeps the number of partitions small.)
PARTITION_COL = "purchase_month"
PARQUET_COMPRESSION = "snappy"

# Every table of the model except the fact. Each one is exported as one CSV.
DIMENSIONS = [
    "dim_category_name_translation",
    "dim_geo",
    "dim_product",
    "dim_customer",
    "dim_carrier",
    "dim_seller",
    "bridge_seller_carrier",
    "dim_dates",
    "dim_review",
    "dim_payment_details",
]

# Month used by query 2. If it has no rows, the busiest month is used instead.
SINGLE_MONTH = "2017-11"

# Timing: 1 warm-up run (discarded) + RUNS measured runs. The median is reported.
RUNS = 10

# Revenue = sum of the item price (freight is not revenue). Change here if needed.
REVENUE = "price"

# After the export, print the first rows of every CSV file that was written.
SHOW_CSV_PREVIEW = True
PREVIEW_ROWS = 5
PREVIEW_COL_WIDTH = 18       # longer values are cut in the preview only

# The same three queries run on every layout. {src} is replaced by the table
# expression that reads that layout.
QUERIES = {
    "Q1 revenue per month": """
        SELECT {pc} AS month, ROUND(SUM({rev}), 2) AS revenue
        FROM {{src}}
        GROUP BY 1
        ORDER BY 1
    """,
    "Q2 one month": """
        SELECT ROUND(SUM({rev}), 2) AS revenue, COUNT(*) AS items
        FROM {{src}}
        WHERE {pc} = '{{month}}'
    """,
    "Q3 top 5 categories": """
        SELECT COALESCE(c.product_category_name_english,
                        c.product_category_name) AS category,
               ROUND(SUM(f.{rev}), 2) AS revenue
        FROM {{src}} f
        JOIN dim_category_name_translation c
          ON f.product_category_name = c.product_category_name
        GROUP BY 1
        ORDER BY revenue DESC, category
        LIMIT 5
    """,
}

# name, folder/file (inside CURATED_DIR), format, partitioned?
# Only the Parquet layout is partitioned; the CSV is a single file.
LAYOUTS = [
    ("CSV", "fact_order_items.csv", "csv", False),
    ("Parquet", "fact_order_items.parquet", "parquet", False),
    ("Parquet partitioned", "fact_order_items_partitioned", "parquet", True),
]


# ============================================================
# HELPERS
# ============================================================

def banner(title: str) -> None:
    print("\n" + "=" * 70)
    print(title)
    print("=" * 70)


def table_exists(con, table: str) -> bool:
    return con.execute(
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = ?",
        [table],
    ).fetchone()[0] > 0


def disk_usage(path: str) -> tuple[int, int]:
    """(total bytes, number of files) of a file or a whole folder."""
    if os.path.isfile(path):
        return os.path.getsize(path), 1
    total, files = 0, 0
    for root, _, names in os.walk(path):
        for name in names:
            total += os.path.getsize(os.path.join(root, name))
            files += 1
    return total, files


def human(n_bytes: float) -> str:
    return (f"{n_bytes / 1024 / 1024:.2f} MB" if n_bytes >= 1024 * 1024
            else f"{n_bytes / 1024:.1f} KB")


def month_query(sql: str) -> str:
    return sql.format(pc=PARTITION_COL, rev=REVENUE)


# ============================================================
# STEP 1A - EXPORT EVERY DIMENSION AS CSV
# ============================================================

def export_dimensions(con) -> None:
    """One CSV per dimension / bridge table, written next to the fact table."""
    banner("EXPORT: DIMENSIONS (CSV)")
    os.makedirs(CURATED_DIR, exist_ok=True)

    for table in DIMENSIONS:
        path = os.path.join(CURATED_DIR, f"{table}.csv")
        if os.path.isfile(path):
            os.remove(path)

        n_rows = con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        # ORDER BY ALL = sort by every column, left to right (the key columns come
        # first): stable, diff-friendly files, even for dim_geo where zip repeats
        con.execute(f"""
            COPY (SELECT * FROM {table} ORDER BY ALL)
            TO '{path}' (FORMAT csv, HEADER true)
        """)
        size, _ = disk_usage(path)
        print(f"  {table:30} {n_rows:>8} rows  {human(size):>10}  -> {table}.csv")


# ============================================================
# STEP 1B - EXPORT THE FACT TABLE IN 3 LAYOUTS
# ============================================================

def export_layouts(con) -> None:
    """
    Write the fact table as CSV (one file), Parquet (one file) and Parquet
    partitioned by purchase_month. Every layout carries the derived column
    purchase_month (from order_purchase_timestamp): stored as a normal column
    in the unpartitioned files, and encoded in the folder name
    (purchase_month=2017-11/) in the partitioned one. This lets the same SQL
    run on every layout.
    """
    banner("EXPORT: FACT TABLE (3 LAYOUTS)")
    os.makedirs(CURATED_DIR, exist_ok=True)

    source = f"""
        SELECT *, strftime(order_purchase_timestamp, '%Y-%m') AS {PARTITION_COL}
        FROM {FACT}
    """
    n_rows = con.execute(f"SELECT COUNT(*) FROM {FACT}").fetchone()[0]
    print(f"Rows in {FACT}: {n_rows}")

    for name, target, fmt, partitioned in LAYOUTS:
        path = os.path.join(CURATED_DIR, target)
        # start clean so old files from a previous run are never mixed in
        if os.path.isdir(path):
            shutil.rmtree(path)
        elif os.path.isfile(path):
            os.remove(path)

        options = ["FORMAT parquet", f"COMPRESSION {PARQUET_COMPRESSION}"] \
            if fmt == "parquet" else ["FORMAT csv", "HEADER true"]
        if partitioned:
            options.append(f"PARTITION_BY ({PARTITION_COL})")

        t0 = time.perf_counter()
        con.execute(f"COPY ({source}) TO '{path}' ({', '.join(options)})")
        elapsed = time.perf_counter() - t0

        size, files = disk_usage(path)
        print(f"  {name:20} -> {target:30} {human(size):>10}  "
              f"{files:>3} file(s)  written in {elapsed:.2f}s")


# ============================================================
# STEP 1C - LOOK AT THE CSV FILES THAT WERE WRITTEN
# ============================================================

def csv_paths() -> list[str]:
    """Every CSV the export wrote: the fact table first, then the dimensions."""
    fact_csv = next(target for name, target, fmt, partitioned in LAYOUTS
                    if fmt == "csv")
    return [os.path.join(CURATED_DIR, fact_csv)] + [
        os.path.join(CURATED_DIR, f"{table}.csv") for table in DIMENSIONS
    ]


def clip(text: str, width: int) -> str:
    return text if len(text) <= width else text[: width - 2] + ".."


def preview_csv(con, path: str) -> None:
    """Print the first rows of one CSV, read back from the file itself."""
    # all_varchar: show the text exactly as stored (a zip prefix such as 01037
    # must not be turned into the number 1037 just for display).
    cur = con.execute(
        f"SELECT * FROM read_csv('{path}', header = true, all_varchar = true) "
        f"LIMIT {PREVIEW_ROWS}"
    )
    columns = [d[0] for d in cur.description]
    rows = [
        ["NULL" if v is None else str(v).replace("\r", " ").replace("\n", " ")
         for v in row]
        for row in cur.fetchall()
    ]
    widths = [
        min(PREVIEW_COL_WIDTH, max([len(col)] + [len(r[i]) for r in rows]))
        for i, col in enumerate(columns)
    ]

    size, _ = disk_usage(path)
    print(f"\n{os.path.basename(path)}  ({human(size)})")
    print("  " + " | ".join(clip(c, w).ljust(w) for c, w in zip(columns, widths)))
    print("  " + "-+-".join("-" * w for w in widths))
    for row in rows:
        print("  " + " | ".join(clip(v, w).ljust(w) for v, w in zip(row, widths)))


def preview_csvs(con) -> None:
    banner(f"PREVIEW: CSV FILES (first {PREVIEW_ROWS} rows of each)")
    print(f"Folder: {os.path.abspath(CURATED_DIR)}")
    print("Shown as stored in the files; an empty cell appears as NULL and "
          f"values longer than {PREVIEW_COL_WIDTH} characters are cut.")
    for path in csv_paths():
        preview_csv(con, path)


# ============================================================
# STEP 2 - HOW TO READ EACH LAYOUT
# ============================================================

def source_expr(con, target: str, fmt: str, partitioned: bool) -> str:
    """Table expression (for FROM) that reads one layout."""
    path = os.path.join(CURATED_DIR, target)

    if fmt == "parquet":
        if partitioned:
            return (f"read_parquet('{path}/*/*.parquet', hive_partitioning = true, "
                    f"hive_types = {{'{PARTITION_COL}': 'VARCHAR'}})")
        return f"read_parquet('{path}')"

    # CSV has no schema inside the file: give the types explicitly so every
    # layout is read with exactly the same types as the fact table.
    types = {r[0]: r[1] for r in con.execute(f"DESCRIBE {FACT}").fetchall()}
    types[PARTITION_COL] = "VARCHAR"
    types_sql = ", ".join(f"'{k}': '{v}'" for k, v in types.items())
    return f"read_csv('{path}', header = true, types = {{{types_sql}}})"


def reference_expr() -> str:
    """The fact table inside DuckDB; used only to check that the results are right."""
    return (f"(SELECT *, strftime(order_purchase_timestamp, '%Y-%m') "
            f"AS {PARTITION_COL} FROM {FACT})")


# ============================================================
# STEP 3 - BENCHMARK
# ============================================================

def pick_month(con) -> str:
    n = con.execute(f"""
        SELECT COUNT(*) FROM {reference_expr()} WHERE {PARTITION_COL} = ?
    """, [SINGLE_MONTH]).fetchone()[0]
    if n > 0:
        return SINGLE_MONTH
    busiest = con.execute(f"""
        SELECT {PARTITION_COL} FROM {reference_expr()}
        GROUP BY 1 ORDER BY COUNT(*) DESC LIMIT 1
    """).fetchone()[0]
    print(f"Month {SINGLE_MONTH} has no data; using the busiest month: {busiest}")
    return busiest


def run_timed(con, sql: str):
    """One warm-up (discarded), then RUNS timed runs. Returns (median ms, rows)."""
    rows = con.execute(sql).fetchall()
    times = []
    for _ in range(RUNS):
        t0 = time.perf_counter()
        rows = con.execute(sql).fetchall()
        times.append((time.perf_counter() - t0) * 1000)
    return statistics.median(times), rows


def same_result(a, b, tol: float = 0.01) -> bool:
    """Compare two result sets; numbers may differ by rounding noise only."""
    if len(a) != len(b):
        return False
    for ra, rb in zip(a, b):
        for x, y in zip(ra, rb):
            if isinstance(x, (int, float)) and isinstance(y, (int, float)):
                if abs(x - y) > tol:
                    return False
            elif x != y:
                return False
    return True


def benchmark(con) -> tuple[dict, dict]:
    banner("BENCHMARK")

    month = pick_month(con)
    print(f"Query 2 month: {month} | runs per query: {RUNS} (median reported)")

    # Correct answers, computed once from the table inside DuckDB
    expected = {}
    for q_name, q_sql in QUERIES.items():
        sql = month_query(q_sql).format(src=reference_expr(), month=month)
        expected[q_name] = con.execute(sql).fetchall()

    print("\nExpected results (from the DuckDB table):")
    for q_name, rows in expected.items():
        shown = rows if len(rows) <= 5 else rows[:3] + [("...",)]
        print(f"  {q_name}: {shown}")

    sizes, times = {}, {}
    for name, target, fmt, partitioned in LAYOUTS:
        sizes[name] = disk_usage(os.path.join(CURATED_DIR, target))
        src = source_expr(con, target, fmt, partitioned)
        times[name] = {}
        for q_name, q_sql in QUERIES.items():
            sql = month_query(q_sql).format(src=src, month=month)
            ms, rows = run_timed(con, sql)
            ok = same_result(rows, expected[q_name])
            times[name][q_name] = (ms, ok)
            if not ok:
                print(f"  !! {name} / {q_name}: result differs from the table")
        print(f"  measured: {name}")
    return sizes, times


# ============================================================
# STEP 4 - REPORT
# ============================================================

def report(sizes: dict, times: dict) -> None:
    banner("RESULTS")
    q_names = list(QUERIES)
    csv_size = sizes["CSV"][0]

    print("File size:")
    print(f"  {'layout':20} {'size':>10} {'files':>6} {'vs CSV':>8}")
    for name, (size, files) in sizes.items():
        print(f"  {name:20} {human(size):>10} {files:>6} {size / csv_size:>7.0%}")

    print("\nQuery time, median in ms (lower is better):")
    print(f"  {'layout':20}" + "".join(f"{q:>24}" for q in q_names))
    for name in sizes:
        cells = "".join(f"{times[name][q][0]:>24.1f}" for q in q_names)
        print(f"  {name:20}{cells}")

    print("\nSpeed-up relative to CSV (x times faster; <1 means slower):")
    print(f"  {'layout':20}" + "".join(f"{q:>24}" for q in q_names))
    for name in sizes:
        cells = "".join(
            f"{times['CSV'][q][0] / times[name][q][0]:>23.1f}x" for q in q_names
        )
        print(f"  {name:20}{cells}")

    wrong = [(n, q) for n in times for q in q_names if not times[n][q][1]]
    print("\nResult check: " + ("all layouts returned the same results as the table."
                                if not wrong else f"MISMATCH in {wrong}"))


# ============================================================
# MAIN
# ============================================================

def main() -> None:
    # Read-only: the export never changes the database.
    con = duckdb.connect(DB_PATH, read_only=True)

    missing = [t for t in [FACT, *DIMENSIONS] if not table_exists(con, t)]
    if missing:
        print(f"Not found in the database: {', '.join(missing)}")
        print("Run profiling.sql and then build_model.sql first.")
        con.close()
        return

    export_dimensions(con)
    export_layouts(con)
    if SHOW_CSV_PREVIEW:
        preview_csvs(con)
    sizes, times = benchmark(con)
    report(sizes, times)

    con.close()


if __name__ == "__main__":
    main()