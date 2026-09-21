# Architecture

## Overview

```
scripts/generate_synthetic_data.py      scripts/load_duckdb.py
        │  6 CSV extracts + manifest             │  landing tables, all VARCHAR
        ▼                                        ▼
   data/raw/*.csv  ───────────────────────►  raw.*  (DuckDB schema)
                                                 │
                                                 │  dbt build
                                                 ▼
          ┌──────────────────────────────────────────────────────────────┐
          │  staging.*        views   cast, rename, dedupe, FLAG defects │
          │  intermediate.*   views   rollups, cost recompute, quality   │
          │  marts.*          tables  fct_ / dim_ / mart_                │
          └──────────────────────────────────────────────────────────────┘
                                                 │
                                                 ▼
                              dashboards/app.py (Streamlit, marts only)
```

Everything runs locally: DuckDB file + dbt-duckdb + Python. No services, no
containers, no cloud account.

## Lineage

```
raw_users ─────────────► stg_users ──────────────────────────────┬─► dim_users
                              └── + stg_conversations ───────────────────────► fct_weekly_cohort_retention
raw_conversations ─────► stg_conversations ─┬─► int_conversation_quality ─┐
raw_intent_predictions ► stg_intent_predictions ┘        │                │
raw_escalations ───────► stg_escalations ────────────────┘                ├─► fct_conversations ─► mart_intent_quality
                                                                          │
raw_llm_requests ──────► stg_llm_requests ──┬─► int_model_costs ──┬───────┼─► fct_llm_requests ─┬─► fct_daily_model_costs
raw_daily_model_prices ► stg_daily_model_prices ┘                 │       │                     └─► mart_model_reliability_daily
seeds/model_aliases ────┘                                         │       │
                                            int_conversation_request_rollup
                                                                  │
                                            int_daily_product_metrics ─► fct_daily_product_metrics ─► mart_daily_anomalies
                                            int_intent_confusion
seeds/model_catalog ─────────────────────────────────────────────────────► dim_models
seeds/intent_catalog ────────────────────────────────────────────────────► dim_intents
```

## Layer contracts

### `raw` (landing)
- Loaded verbatim from CSV with `all_varchar = true`. Types are *not* inferred
  on load — the realistic case for JSON/CSV landing zones — so every cast is an
  explicit, reviewable decision in staging.
- `_ingested_at` (from the source system) and `_loaded_at` (set by the loader)
  are kept separate: the first drives late-arrival logic, the second drives
  source freshness.
- Source tests run at `warn` severity. They are documentation of upstream
  defects, not gates.

### `staging` (one model per source, views)
- One-to-one with sources. No joins between sources except the alias seed.
- Responsibilities: cast, rename to `snake_case` with unit suffixes
  (`_ms`, `_usd`, `_seconds`), standardise booleans/timestamps, derive
  `*_date`, buckets, and **quality flags**.
- Rule: *never drop, always flag* (see `docs/data_quality_notes.md`). The
  only row reduction is deduplication of exact replays.
- Tests here run at `error` severity — they prove the cleaning worked.

### `intermediate` (views)
- Business logic that is reused by more than one mart, or too heavy to read
  inline: cost recomputation, conversation rollups, daily additive components,
  confusion matrix.
- `int_daily_product_metrics` holds **counts and sums only**. Ratios are
  computed one layer up so any re-aggregation can be done from additive
  parts.

### `marts` (tables)
- `fct_*` — one row per business event (conversation, request, day, day×model).
- `dim_*` — catalogues enriched with observed usage.
- `mart_*` — pre-shaped for one dashboard view; may denormalise freely.
  `mart_daily_anomalies` is the one mart that reads another mart
  (`fct_daily_product_metrics`) rather than intermediates: it is a
  monitoring layer on top of the published KPIs, and must see exactly what
  the dashboard sees.
- Consumers (dashboard, ad-hoc SQL) read *only* this schema.

## Key design decisions

| Decision | Alternative considered | Why this one |
|---|---|---|
| DuckDB file, not Postgres | Postgres in Docker | Zero-setup, sub-second full rebuild, same SQL dialect breadth (window fns, `quantile_cont`, `filter`). The trade-off is single-writer: stop the dashboard before `dbt build`. |
| Recompute cost from tokens × price list; treat logged cost as untrusted | Trust the logged `cost_usd` | The service that logs cost is not the system of record for prices. Recomputing makes finance reconciliation a first-class test instead of a quarterly surprise. |
| Escalation wins over "resolved" on conflict | Resolved wins / null out both | The escalation is corroborated by an independent hand-off record; "resolved" is a self-reported flag. Conflicts are still surfaced via a warn-test. |
| Orphan requests kept in cost, excluded from per-conversation KPIs | Drop orphans | Provider bills them; excluding them would understate spend. Per-conversation unit economics must not be diluted by unattributable rows. |
| Accuracy on the human-reviewed subset only | Use `predicted == initial_intent` for all rows | `initial_intent` in the conversation feed *is* the model's routing decision — using it as truth would be circular. Only human labels count, and `n_reviewed` is always shown next to accuracy. |
| Daily spine spans union of conversation and request dates; trailing day flagged `is_partial_day` | Spine from conversations only | Requests spill past midnight on the last day; a spine built from one side silently drops them (caught by a reconciliation test during development). |
| Views for staging/intermediate, tables for marts | Everything as tables | Rebuild is ~2 s; views keep the warehouse file small and avoid stale intermediates. Marts are tables because the dashboard queries them repeatedly. |
| Anomaly baseline = median/MAD with per-kind floors, in SQL | Mean/stddev; a Python job with Prophet/STL | Median/MAD is not inflated by the incident it is meant to catch; per-kind floors handle Poisson counts and weekly seasonality without a model. Stays inside dbt, so it is tested and versioned like every other mart. |
| Cohorts on user-relative weeks, only fully-in-window signup weeks, explicit observability flag | Calendar-week alignment; include pre-window users | User-relative weeks make week 0 mean the same thing for everyone; pre-window users have no observable week 0 and would drag it down; the flag keeps partial cells honest instead of dropping them. |
| Seeds for aliases and catalogues | Hard-code in SQL `case` expressions | Seeds are diff-able, testable (`unique`, `accepted_values`) and editable by non-engineers. |

## Running order

```
python scripts/generate_synthetic_data.py   # ~4 s, deterministic (seed 42)
python scripts/load_duckdb.py               # raw.* + audit.messy_manifest
dbt deps && dbt build --profiles-dir .      # seeds → models → tests
streamlit run dashboards/app.py
```

`dbt build` is idempotent; the whole chain from CSV to marts runs in well
under a minute on a laptop.

## What would change at scale

- **Incremental models** for `stg_llm_requests` / `fct_llm_requests` keyed on
  `ingested_at` with a look-back window driven by `is_late_arriving`.
- **Partitioned marts** by `request_date` on a warehouse target (BigQuery /
  Snowflake); the SQL is portable apart from `quantile_cont`, `arg_max`,
  `filter (where …)` which have direct equivalents.
- **Source freshness** would move from `_loaded_at` to the pipeline's actual
  landing timestamp and gate downstream runs.
- **Orchestration** (Dagster/Airflow) only once there is more than one
  producer; today a single `dbt build` is the DAG.
