{#-
    One row per conversation: outcome, quality signals and LLM usage/cost.
    Conversations with zero LLM requests are kept (n_requests = 0) - they are
    real product sessions and matter for auto-resolution and escalation rates.
-#}
with conversations as (
    select * from {{ ref('stg_conversations') }}
),

rollup as (
    select * from {{ ref('int_conversation_request_rollup') }}
),

quality as (
    select * from {{ ref('int_conversation_quality') }}
),

users as (
    select user_id, segment, country_code, signup_channel, signup_week
    from {{ ref('stg_users') }}
)

select
    c.conversation_id,
    c.user_id,
    u.segment                                           as user_segment,
    u.country_code                                      as user_country_code,
    u.signup_channel                                    as user_signup_channel,
    u.signup_week                                       as user_signup_week,
    c.started_at,
    c.ended_at,
    c.conversation_date,
    c.duration_seconds,
    c.channel,
    c.initial_intent,

    -- outcome
    c.resolution_status,
    c.is_auto_resolved,
    c.is_escalated,
    c.resolution_status = 'abandoned'                   as is_abandoned,
    c.has_conflicting_resolution,
    c.satisfaction_score,
    c.has_satisfaction_score,

    -- escalation
    q.escalation_reason,
    q.handled_by_team,
    q.time_to_handoff_seconds,

    -- intent classification
    q.predicted_intent,
    q.confidence                                        as intent_confidence,
    q.confidence_bucket                                 as intent_confidence_bucket,
    q.is_human_reviewed                                 as intent_is_human_reviewed,
    q.is_correct                                        as intent_is_correct,
    q.is_corrected                                      as intent_is_corrected,

    -- LLM usage
    coalesce(r.n_requests, 0)                           as n_requests,
    coalesce(r.n_successful_requests, 0)                as n_successful_requests,
    coalesce(r.n_failed_requests, 0)                    as n_failed_requests,
    coalesce(r.had_failed_request, false)               as had_failed_request,
    coalesce(r.n_distinct_models, 0)                    as n_distinct_models,
    r.first_model_name,
    r.last_model_name,
    coalesce(r.prompt_tokens, 0)                        as prompt_tokens,
    coalesce(r.completion_tokens, 0)                    as completion_tokens,
    coalesce(r.total_tokens, 0)                         as total_tokens,
    coalesce(r.cost_usd, 0)                             as cost_usd,
    r.avg_latency_ms,
    r.max_latency_ms,
    r.total_latency_ms,
    coalesce(r.had_data_quality_issue, false)           as had_data_quality_issue
from conversations as c
left join rollup as r using (conversation_id)
left join quality as q using (conversation_id)
left join users as u using (user_id)
