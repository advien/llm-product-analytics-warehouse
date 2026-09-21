# Metric definitions

Every metric below is materialised in a mart table; the dashboard never
computes business logic of its own. Grain and source model are given so a
number on a chart can be traced to one SQL expression.

Conventions:

- **Conversation-level metrics** are keyed on `conversation_date`
  (= `started_at::date`). A conversation that crosses midnight belongs to the
  day it started.
- **Request-level metrics** are keyed on `request_date` (= `created_at::date`).
- **Cost** always means `calculated_cost_usd` = tokens × price-list rate on the
  request date. The value the orchestration service logged is carried as
  `logged_cost_usd` for reconciliation only and is never used in a KPI.
- Rates are computed from additive components (`n_x / n_total`) in the mart,
  never averaged across days. Weekly/monthly numbers must be re-derived from the
  components in `int_daily_product_metrics`, not by averaging daily rates.

## Product health

| Metric | Definition | Mart / column |
|---|---|---|
| Conversations | Count of conversations started on the day | `fct_daily_product_metrics.n_conversations` |
| Active users | Distinct `user_id` with ≥1 conversation started on the day | `fct_daily_product_metrics.n_active_users` |
| Auto-resolution rate | `n_auto_resolved / n_conversations`, where auto-resolved = raw `resolved_without_escalation` **and not** escalated | `fct_daily_product_metrics.auto_resolution_rate` |
| Escalation rate | `n_escalated / n_conversations`; escalated wins when both raw flags are set | `fct_daily_product_metrics.escalation_rate` |
| Abandonment rate | `n_abandoned / n_conversations`; neither resolved nor escalated | `fct_daily_product_metrics.abandonment_rate` |
| Avg satisfaction | Mean of 1–5 rating over rated conversations only (`n_rated`); ~35% of conversations are unrated and excluded, not imputed | `fct_daily_product_metrics.avg_satisfaction_score` |
| Rating response rate | `n_rated / n_conversations` — shown alongside CSAT so a CSAT move can be read against response bias | `fct_daily_product_metrics.rating_response_rate` |
| Requests per conversation | `n_requests_in_conversations / n_conversations` (orphan requests excluded from numerator) | `fct_daily_product_metrics.avg_requests_per_conversation` |
| Satisfaction by intent | Mean rating grouped by `initial_intent` | `mart_intent_quality.avg_satisfaction_score` |
| Escalation reason distribution | Count of escalated conversations by `escalation_reason`; modal reason per intent | `fct_conversations.escalation_reason`, `mart_intent_quality.top_escalation_reason` |

## LLM cost

| Metric | Definition | Mart / column |
|---|---|---|
| Total daily LLM cost | Σ `calculated_cost_usd` over all requests on the day, **including orphans** (the provider bills them regardless) | `fct_daily_product_metrics.total_cost_usd`, `fct_daily_model_costs.total_cost_usd` |
| Cost per request | `total_cost_usd / n_requests` | `fct_daily_product_metrics.cost_per_request_usd` |
| Cost per conversation | cost of requests **attached** to conversations started that day / `n_conversations`. Orphans are excluded so the unit economics are not polluted by unattributable spend | `fct_daily_product_metrics.cost_per_conversation_usd` |
| Cost per auto-resolved conversation | same numerator / `n_auto_resolved` — the "cost of a deflected ticket" | `fct_daily_product_metrics.cost_per_auto_resolved_conversation_usd` |
| Cost by model / provider | Σ cost grouped by (date, provider, model) | `fct_daily_model_costs` |
| Token usage | Σ prompt / completion / total tokens by (date, model). `total_tokens` is always recomputed as prompt + completion | `fct_daily_model_costs.*_tokens` |
| Effective cost per 1k tokens | `total_cost_usd / total_tokens × 1000` — blends input/output mix, useful to compare models on the *actual* workload | `fct_daily_model_costs.cost_per_1k_tokens_usd` |
| Wasted cost on failures | Σ cost of requests with status ≠ success (prompt tokens are still billed) | `fct_daily_model_costs.wasted_cost_on_failures_usd` |
| Cost reconciliation delta | `total_cost_usd − total_logged_cost_usd`; non-zero means the service's price sheet drifted | `fct_daily_product_metrics.cost_reconciliation_delta_usd` |

## Reliability

| Metric | Definition | Mart / column |
|---|---|---|
| Error rate | `n_failed_requests / n_requests`, failed = status ∈ {error, timeout, rate_limited} | `fct_daily_product_metrics.error_rate` |
| Timeout rate | `n_timeout_requests / n_requests` | `fct_daily_product_metrics.timeout_rate` |
| Avg latency | mean `latency_ms` over requests with a valid (non-negative) raw latency | `fct_daily_product_metrics.avg_latency_ms` |
| p50 / p95 / p99 latency | `quantile_cont` over the same population. Timeouts (30–60 s) are included, which is why p99 sits near the timeout ceiling | `fct_daily_product_metrics.p50/p95/p99_latency_ms` |
| p95 success latency | p95 over successful requests only — what a user actually waited for an answer | `mart_model_reliability_daily.p95_success_latency_ms` |
| Latency by model | percentiles grouped by (date, model) | `mart_model_reliability_daily` |
| Failed request breakdown | counts by status and by `error_type` (provider_5xx, content_filter, context_length, invalid_request, upstream_timeout, rate_limit_429) | `mart_model_reliability_daily.n_*` |

## Quality

The intent classifier runs once at the start of each conversation. Only ~30% of
predictions receive a human review label, so **accuracy metrics are computed on
the reviewed subset only** and `n_reviewed_predictions` is always exposed next
to them.

| Metric | Definition | Mart / column |
|---|---|---|
| Intent accuracy | `n_correct / n_reviewed`, correct = human label equals prediction | `fct_daily_product_metrics.intent_accuracy`, `mart_intent_quality.intent_accuracy` |
| Corrected-intent rate | `n_corrected / n_reviewed`, corrected = human label present and different from prediction | `fct_daily_product_metrics.corrected_intent_rate` |
| Confidence distribution | conversations bucketed by classifier confidence (<0.5, 0.5–0.69, 0.7–0.79, 0.8–0.89, 0.9+) | `fct_conversations.intent_confidence_bucket` |
| Low-confidence share | share of conversations with confidence < 0.7 (all conversations, not just reviewed) | `mart_intent_quality.low_confidence_share` |
| Confusion matrix | (actual, predicted) pairs with counts and row-normalised share, reviewed subset | `int_intent_confusion` |
| Escalation by intent | escalation rate and modal reason per intent | `mart_intent_quality` |

## Dimensions

| Table | Grain | Notable attributes |
|---|---|---|
| `dim_users` | user | segment, country, signup channel/week, lifetime conversations and LLM cost, days to first conversation |
| `dim_models` | model | provider, routing tier, current price, number of price changes in window, requests via alias |
| `dim_intents` | intent | category, risk level, whether policy requires human hand-off |

## Deliberately not implemented

- **Cost per token as a KPI in `fct_daily_product_metrics`** for individual
  models — it lives in `fct_daily_model_costs` because it is only meaningful
  per model.
- **Weekly cohort retention** — `dim_users.signup_week` and
  `fct_conversations.user_signup_week` are in place; the cohort matrix is a
  natural follow-up (see README → Future improvements).
