{#-
    Per-intent quality and operations view. Grain: one row per intent in the
    catalogue. Classification metrics come from the human-reviewed subset only.
    `top_escalation_reason` is the modal reason among escalated conversations.
-#}
with conversations as (
    select * from {{ ref('fct_conversations') }}
),

intents as (
    select * from {{ ref('dim_intents') }}
),

reason_ranked as (
    select
        initial_intent,
        escalation_reason,
        count(*)                                                    as n,
        row_number() over (partition by initial_intent order by count(*) desc, escalation_reason) as rn
    from conversations
    where is_escalated and escalation_reason is not null
    group by 1, 2
),

per_intent as (
    select
        initial_intent                                              as intent,
        count(*)                                                    as n_conversations,
        count(distinct user_id)                                     as n_users,
        count(*) filter (where is_auto_resolved)                    as n_auto_resolved,
        count(*) filter (where is_escalated)                        as n_escalated,
        count(*) filter (where is_abandoned)                        as n_abandoned,
        count(*) filter (where is_auto_resolved) * 1.0 / count(*)   as auto_resolution_rate,
        count(*) filter (where is_escalated) * 1.0 / count(*)       as escalation_rate,
        avg(satisfaction_score)                                     as avg_satisfaction_score,
        count(satisfaction_score)                                   as n_rated,
        avg(time_to_handoff_seconds)                                as avg_time_to_handoff_seconds,

        -- classifier quality on this intent (rows where the human label == this intent)
        count(*) filter (where intent_is_human_reviewed)            as n_reviewed_predictions,
        count(*) filter (where intent_is_correct)                   as n_correct_predictions,
        count(*) filter (where intent_is_corrected)                 as n_corrected_predictions,
        count(*) filter (where intent_is_correct) * 1.0
            / nullif(count(*) filter (where intent_is_human_reviewed), 0) as intent_accuracy,
        count(*) filter (where intent_is_corrected) * 1.0
            / nullif(count(*) filter (where intent_is_human_reviewed), 0) as corrected_intent_rate,
        avg(intent_confidence)                                      as avg_intent_confidence,
        count(*) filter (where intent_confidence < 0.7) * 1.0 / count(*) as low_confidence_share,

        -- economics
        sum(cost_usd)                                               as total_cost_usd,
        sum(cost_usd) / count(*)                                    as cost_per_conversation_usd,
        sum(cost_usd) / nullif(count(*) filter (where is_auto_resolved), 0) as cost_per_auto_resolved_usd,
        avg(n_requests)                                             as avg_requests_per_conversation,
        avg(avg_latency_ms)                                         as avg_latency_ms
    from conversations
    group by 1
)

select
    i.intent,
    i.intent_category,
    i.risk_level,
    i.requires_human_policy,
    p.* exclude (intent),
    r.escalation_reason                                             as top_escalation_reason,
    r.n * 1.0 / nullif(p.n_escalated, 0)                            as top_escalation_reason_share
from intents as i
left join per_intent as p using (intent)
left join reason_ranked as r
    on i.intent = r.initial_intent
    and r.rn = 1
