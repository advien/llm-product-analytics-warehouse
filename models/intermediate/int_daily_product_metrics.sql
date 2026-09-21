{#-
    Daily metric COMPONENTS (counts and sums), not ratios. Ratios are derived in
    fct_daily_product_metrics so that any re-aggregation (weekly, monthly, by
    segment) can be done from additive parts without averaging averages.

    Two grains are combined on the calendar date:
      * conversation-side, keyed on conversation_date (started_at)
      * request-side, keyed on request_date (created_at), includes orphans
    A day with requests but no conversations (or vice versa) is still emitted.
-#}
with date_bounds as (
    select
        least(
            (select min(conversation_date) from {{ ref('stg_conversations') }}),
            (select min(request_date) from {{ ref('stg_llm_requests') }})
        ) as min_date,
        greatest(
            (select max(conversation_date) from {{ ref('stg_conversations') }}),
            (select max(request_date) from {{ ref('stg_llm_requests') }})
        ) as max_date
),

calendar as (
    select cast(unnest(generate_series(min_date, max_date, interval 1 day)) as date) as metric_date
    from date_bounds
),

conversation_side as (
    select
        c.conversation_date                                                 as metric_date,
        count(*)                                                            as n_conversations,
        count(distinct c.user_id)                                           as n_active_users,
        count(*) filter (where c.is_auto_resolved)                          as n_auto_resolved,
        count(*) filter (where c.is_escalated)                              as n_escalated,
        count(*) filter (where c.resolution_status = 'abandoned')           as n_abandoned,
        count(*) filter (where c.has_satisfaction_score)                    as n_rated,
        sum(c.satisfaction_score)                                           as satisfaction_score_sum,
        count(*) filter (where q.is_human_reviewed)                         as n_reviewed_predictions,
        count(*) filter (where q.is_correct)                                as n_correct_predictions,
        count(*) filter (where q.is_corrected)                              as n_corrected_predictions,
        sum(r.n_requests)                                                   as n_requests_in_conversations,
        sum(r.cost_usd)                                                     as conversation_cost_usd
    from {{ ref('stg_conversations') }} as c
    left join {{ ref('int_conversation_quality') }} as q using (conversation_id)
    left join {{ ref('int_conversation_request_rollup') }} as r using (conversation_id)
    group by 1
),

request_side as (
    select
        r.request_date                                                      as metric_date,
        count(*)                                                            as n_requests,
        count(*) filter (where r.is_success)                                as n_successful_requests,
        count(*) filter (where r.is_failed)                                 as n_failed_requests,
        count(*) filter (where r.status = 'error')                          as n_error_requests,
        count(*) filter (where r.status = 'timeout')                        as n_timeout_requests,
        count(*) filter (where r.status = 'rate_limited')                   as n_rate_limited_requests,
        count(*) filter (where r.is_orphan)                                 as n_orphan_requests,
        sum(r.prompt_tokens)                                                as prompt_tokens,
        sum(r.completion_tokens)                                            as completion_tokens,
        sum(r.total_tokens)                                                 as total_tokens,
        sum(m.calculated_cost_usd)                                          as cost_usd,
        sum(m.recorded_cost_usd)                                            as logged_cost_usd,
        count(*) filter (where not m.is_cost_reconciled)                    as n_cost_mismatches,
        count(r.latency_ms)                                                 as n_latency_samples,
        sum(r.latency_ms)                                                   as latency_ms_sum,
        quantile_cont(r.latency_ms, 0.50)                                   as p50_latency_ms,
        quantile_cont(r.latency_ms, 0.95)                                   as p95_latency_ms,
        quantile_cont(r.latency_ms, 0.99)                                   as p99_latency_ms
    from {{ ref('stg_llm_requests') }} as r
    inner join {{ ref('int_model_costs') }} as m using (request_id)
    group by 1
)

select
    cal.metric_date,
    coalesce(cs.n_conversations, 0)             as n_conversations,
    coalesce(cs.n_active_users, 0)              as n_active_users,
    coalesce(cs.n_auto_resolved, 0)             as n_auto_resolved,
    coalesce(cs.n_escalated, 0)                 as n_escalated,
    coalesce(cs.n_abandoned, 0)                 as n_abandoned,
    coalesce(cs.n_rated, 0)                     as n_rated,
    coalesce(cs.satisfaction_score_sum, 0)      as satisfaction_score_sum,
    coalesce(cs.n_reviewed_predictions, 0)      as n_reviewed_predictions,
    coalesce(cs.n_correct_predictions, 0)       as n_correct_predictions,
    coalesce(cs.n_corrected_predictions, 0)     as n_corrected_predictions,
    coalesce(cs.n_requests_in_conversations, 0) as n_requests_in_conversations,
    coalesce(cs.conversation_cost_usd, 0)       as conversation_cost_usd,
    coalesce(rs.n_requests, 0)                  as n_requests,
    coalesce(rs.n_successful_requests, 0)       as n_successful_requests,
    coalesce(rs.n_failed_requests, 0)           as n_failed_requests,
    coalesce(rs.n_error_requests, 0)            as n_error_requests,
    coalesce(rs.n_timeout_requests, 0)          as n_timeout_requests,
    coalesce(rs.n_rate_limited_requests, 0)     as n_rate_limited_requests,
    coalesce(rs.n_orphan_requests, 0)           as n_orphan_requests,
    coalesce(rs.prompt_tokens, 0)               as prompt_tokens,
    coalesce(rs.completion_tokens, 0)           as completion_tokens,
    coalesce(rs.total_tokens, 0)                as total_tokens,
    coalesce(rs.cost_usd, 0)                    as cost_usd,
    coalesce(rs.logged_cost_usd, 0)             as logged_cost_usd,
    coalesce(rs.n_cost_mismatches, 0)           as n_cost_mismatches,
    coalesce(rs.n_latency_samples, 0)           as n_latency_samples,
    coalesce(rs.latency_ms_sum, 0)              as latency_ms_sum,
    rs.p50_latency_ms,
    rs.p95_latency_ms,
    rs.p99_latency_ms
from calendar as cal
left join conversation_side as cs using (metric_date)
left join request_side as rs using (metric_date)
