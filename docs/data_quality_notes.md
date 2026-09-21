# Data quality notes

The raw feeds are intentionally dirty. The generator injects eight classes of
defect at realistic rates and records every affected key in
`audit.messy_manifest`, so every cleaning rule can be checked against ground
truth. This document explains, per defect: what it looks like in raw, how the
pipeline handles it, and which test proves it.

## Principle: flag, don't drop

Staging models never silently discard a row. Each defect becomes a boolean
flag that travels through to the marts (`fct_llm_requests.has_*`,
`fct_conversations.has_conflicting_resolution`), so a consumer can always
ask "how much of this number rests on repaired data?". Only exact duplicate
ingests are collapsed, and even then `had_duplicate_ingest` marks the survivor.

## Test layering

| Layer | Severity | Purpose |
|---|---|---|
| `source:` tests on `raw.*` | **warn** | Document that the defect exists upstream. These fire on every build and are expected to. |
| Tests on `stg_*` | error | Prove the staging rule fixed it. |
| Tests on `int_*` / marts | error | Guard the modelling logic (grain, additivity, reconciliation between marts). |
| `tests/warn_*.sql` | warn | Visibility lists for defects that are repaired but worth tracking upstream. |
| `tests/assert_*.sql` | error | Cross-mart invariants and SLO-style thresholds. |

Current build: **177 pass / 6 warn / 0 error** (4 raw-level warnings + 2 visibility warnings).

## Defect catalogue

### 1. Duplicate `request_id` (at-least-once delivery)
- **Raw:** 294 request rows are exact replays with a later `_ingested_at`.
- **Detected by:** `source_unique_raw_raw_llm_requests_request_id` (warn 294).
- **Handling:** `stg_llm_requests` keeps the earliest-ingested copy
  (`row_number() over (partition by request_id order by ingested_at)`), sets
  `had_duplicate_ingest = true` on the survivor.
- **Proof:** `unique_stg_llm_requests_request_id` passes; `fct_llm_requests` has
  98,243 rows = 98,537 raw − 294.

### 2. Missing `conversation_id` (orphan requests)
- **Raw:** 196 requests with a null conversation reference.
- **Detected by:** `source_not_null_raw_raw_llm_requests_conversation_id` (warn 196).
- **Handling:** kept, `is_orphan = true`. Included in total cost and error
  rate (the provider billed them, the failure happened), **excluded** from
  cost-per-conversation and requests-per-conversation.
- **Proof:** `assert_conversation_cost_matches_request_ledger` — Σ
  `fct_conversations.cost_usd` equals Σ non-orphan `fct_llm_requests.cost_usd`.

### 3. Negative latency (client clock skew)
- **Raw:** 98 rows with `latency_ms < 0`.
- **Detected by:** `dbt_utils.expression_is_true` on the source (warn 98).
- **Handling:** `latency_ms` set to NULL, `raw_latency_ms` preserved,
  `has_invalid_latency = true`. All latency aggregates use `latency_ms`, so
  these rows drop out of averages and percentiles but still count as requests.
- **Proof:** `accepted_range` (min 0) on `stg_llm_requests.latency_ms` and
  `fct_llm_requests.latency_ms` pass.

### 4. `total_tokens ≠ prompt + completion` (double-counted system prompt)
- **Raw:** 491 rows where the reported total is inflated.
- **Detected by:** source expression test (warn 491).
- **Handling:** `total_tokens` is **always** recomputed as
  `prompt_tokens + completion_tokens`; the reported value is kept as
  `raw_total_tokens`, `has_token_sum_mismatch = true`.
- **Proof:** `expression_is_true: total_tokens = prompt_tokens + completion_tokens`
  on staging passes.

### 5. Model name not in the price list (preview aliases)
- **Raw:** 196 requests logged with a `-preview` suffix (`gpt-4o-mini-preview`, …).
- **Handling:** the `model_aliases` seed maps aliases → canonical names in
  staging (`has_model_alias = true`, `model_name_raw` kept). A genuinely new,
  unpriced model would surface as a **failure** of the
  `relationships(stg_llm_requests.model_name → stg_daily_model_prices)` test
  and `int_model_costs.is_missing_price` — which is the desired behaviour:
  ship the price row (or the alias) before the model reaches production.
- **Proof:** both tests pass; `dim_models.n_requests_via_alias` shows the
  volume per model.

### 6. Conversations both resolved-without-escalation **and** escalated
- **Raw:** 136 conversations with contradictory flags.
- **Handling:** `stg_conversations` derives a single `resolution_status`
  (`escalated` > `auto_resolved` > `abandoned`). Escalation wins because it is
  corroborated by an independent hand-off record in `raw_escalations`.
  `has_conflicting_resolution = true` is kept.
- **Proof:** `expression_is_true: not (is_auto_resolved and is_escalated)` on
  staging and on `fct_conversations`; `warn_conversations_with_conflicting_raw_flags`
  lists the 136 for the upstream team.
- **Cross-check:** `int_conversation_quality.is_escalated_without_record` and
  `has_record_without_escalation_flag` are tested to be always false, so the
  conversation flag and the escalation table never disagree after staging.

### 7. Late-arriving events
- **Raw:** 392 requests ingested 2–5 days after `created_at`.
- **Handling:** `is_late_arriving = true` when ingestion lags the event by
  more than 60 minutes. Metrics are keyed on **event time** (`created_at`), so
  late rows land on the correct day. In an incremental setup this flag is what
  would drive a look-back window; here the full rebuild makes it informational.
- **Freshness:** source freshness is declared on `_loaded_at` (the landing
  timestamp), not on the event timestamp, so a 90-day-old synthetic dataset
  does not trip the check on every run.

### 8. Logged cost computed from a lagging price sheet
- **Raw:** 389 requests (≈1% of three models) whose `cost_usd` was computed
  by the orchestration service with an out-of-date embedded price sheet
  (+20–50% vs the finance price list).
- **Handling:** `int_model_costs` recomputes `calculated_cost_usd` from tokens
  × `stg_daily_model_prices` on the request date and flags
  `is_cost_reconciled` using a tolerance of max(0.5 % relative, $0.00001
  absolute). **All marts use the recomputed cost.**
- **Proof / visibility:**
  - `warn_unreconciled_request_costs` lists the 389 rows (warn).
  - `assert_cost_mismatch_rate_within_slo` fails if any day exceeds 2 %
    mismatches (passes; the observed daily rate is ≈0.4 %).
  - `assert_daily_cost_reconciles_between_marts` ensures the KPI mart and the
    per-model ledger agree to $0.0001 per day.
  - The dashboard's *Data quality* tab shows logged vs recomputed cost per
    model, where the drift is concentrated in `gpt-4.1`, `claude-sonnet-4-5`
    and `gemini-2.5-flash`.

## Things the tests caught during development

Worth recording because they are the kind of bug this layering exists for:

- **Calendar spine dropped a day.** The first version of
  `int_daily_product_metrics` built its date spine from conversation dates
  only. Requests belonging to conversations that crossed midnight on the last
  day landed on a date with no spine row and vanished from the KPI mart
  while still being present in the per-model ledger — a $0.0006 discrepancy.
  `assert_daily_cost_reconciles_between_marts` and
  `assert_every_request_date_has_daily_metrics` now pin this down; the spine
  spans the union of both date ranges and the trailing spill-over day is
  flagged `is_partial_day`.
- **Tolerance too loose.** An absolute tolerance of $0.0001 hid a 7 % drift on
  sub-cent `gpt-4o-mini` requests entirely. Lowered to $0.00001 (the 6-decimal
  rounding floor) so relative drift dominates for every model.

## What is *not* tested (and why)

- No test asserts a metric's absolute level (e.g. "escalation rate < 25 %").
  Those are product SLOs, not data-quality invariants, and belong in
  monitoring/alerting on top of the marts.
- Anomaly flags (`mart_daily_anomalies`) are tested for *mechanics* (grain,
  a flag requires a z-score, actionable ⊂ anomaly) and by one regression
  fixture: `assert_anomaly_detector_flags_provider_incident` requires the
  planted 14 July incident to be flagged on error rate, timeout rate and p95
  latency, and error rate to fire on at most two other days. That test
  encodes a property of the synthetic dataset, not a business rule — it is
  a test of the detector, and says so in its header.
