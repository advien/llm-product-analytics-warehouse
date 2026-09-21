{#-
    Daily product KPIs, one row per calendar day. Every ratio is computed from
    the additive components in int_daily_product_metrics; the components are
    carried along so a consumer can re-aggregate to weeks/months correctly.

    Rate definitions (see docs/metric_definitions.md):
      auto_resolution_rate = auto-resolved / conversations
      escalation_rate      = escalated / conversations
      error_rate           = failed requests / requests  (error + timeout + rate_limited)
      cost_per_conversation uses cost of requests ATTACHED to conversations;
      cost_per_request and total cost include orphan requests.
-#}
with daily as (
    select * from {{ ref('int_daily_product_metrics') }}
)

select
    metric_date,
    dayname(metric_date)                                            as day_of_week,
    date_trunc('week', metric_date)                                 as week_start_date,

    -- product health
    n_conversations,
    n_active_users,
    n_auto_resolved,
    n_escalated,
    n_abandoned,
    n_auto_resolved * 1.0 / nullif(n_conversations, 0)              as auto_resolution_rate,
    n_escalated * 1.0 / nullif(n_conversations, 0)                  as escalation_rate,
    n_abandoned * 1.0 / nullif(n_conversations, 0)                  as abandonment_rate,
    n_rated,
    satisfaction_score_sum * 1.0 / nullif(n_rated, 0)               as avg_satisfaction_score,
    n_rated * 1.0 / nullif(n_conversations, 0)                      as rating_response_rate,

    -- usage
    n_requests,
    n_requests_in_conversations,
    n_orphan_requests,
    n_requests_in_conversations * 1.0 / nullif(n_conversations, 0)  as avg_requests_per_conversation,
    prompt_tokens,
    completion_tokens,
    total_tokens,

    -- reliability
    n_successful_requests,
    n_failed_requests,
    n_error_requests,
    n_timeout_requests,
    n_rate_limited_requests,
    n_failed_requests * 1.0 / nullif(n_requests, 0)                 as error_rate,
    n_timeout_requests * 1.0 / nullif(n_requests, 0)                as timeout_rate,
    latency_ms_sum * 1.0 / nullif(n_latency_samples, 0)             as avg_latency_ms,
    p50_latency_ms,
    p95_latency_ms,
    p99_latency_ms,

    -- cost
    cost_usd                                                        as total_cost_usd,
    logged_cost_usd                                                 as total_logged_cost_usd,
    cost_usd - logged_cost_usd                                      as cost_reconciliation_delta_usd,
    n_cost_mismatches,
    cost_usd / nullif(n_requests, 0)                                as cost_per_request_usd,
    conversation_cost_usd / nullif(n_conversations, 0)              as cost_per_conversation_usd,
    conversation_cost_usd / nullif(n_auto_resolved, 0)              as cost_per_auto_resolved_conversation_usd,
    cost_usd / nullif(total_tokens, 0) * 1000                       as cost_per_1k_tokens_usd,

    -- intent quality (human-reviewed subset)
    n_reviewed_predictions,
    n_correct_predictions,
    n_corrected_predictions,
    n_correct_predictions * 1.0 / nullif(n_reviewed_predictions, 0)   as intent_accuracy,
    n_corrected_predictions * 1.0 / nullif(n_reviewed_predictions, 0) as corrected_intent_rate
from daily
