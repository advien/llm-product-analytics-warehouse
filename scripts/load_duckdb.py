"""Load raw CSV extracts into the DuckDB warehouse under the `raw` schema.

Mirrors an EL step (e.g. Fivetran/Airbyte landing tables): types are kept as
loose as the source emits them, nothing is cleaned here. All cleaning is dbt's
job in the staging layer.

Usage:
    python scripts/load_duckdb.py [--db data/processed/warehouse.duckdb]
"""

from __future__ import annotations

import argparse
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = ROOT / "data" / "raw"

TABLES = [
    "raw_users",
    "raw_conversations",
    "raw_llm_requests",
    "raw_intent_predictions",
    "raw_escalations",
    "raw_daily_model_prices",
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=str(ROOT / "data" / "processed" / "warehouse.duckdb"))
    args = ap.parse_args()

    Path(args.db).parent.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(args.db)
    con.execute("CREATE SCHEMA IF NOT EXISTS raw")

    for name in TABLES:
        path = (RAW_DIR / f"{name}.csv").as_posix()
        # Land everything as read by the CSV sniffer; timestamps stay strings on purpose
        # so staging has to cast them (the realistic case with JSON/CSV landing zones).
        con.execute(f"""
            CREATE OR REPLACE TABLE raw.{name} AS
            SELECT *, current_timestamp AS _loaded_at
            FROM read_csv('{path}', header = true, all_varchar = true)
        """)
        n = con.execute(f"SELECT count(*) FROM raw.{name}").fetchone()[0]
        print(f"raw.{name:24s} {n:>8,d} rows")

    # Ground-truth manifest of injected data-quality issues, kept outside `raw`
    # so it is obviously not a product source.
    con.execute("CREATE SCHEMA IF NOT EXISTS audit")
    con.execute(f"""
        CREATE OR REPLACE TABLE audit.messy_manifest AS
        SELECT * FROM read_csv('{(RAW_DIR / "_messy_manifest.csv").as_posix()}', header = true, all_varchar = true)
    """)
    con.close()
    print(f"\nwarehouse: {args.db}")


if __name__ == "__main__":
    main()
