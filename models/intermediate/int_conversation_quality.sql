{#-
    Conversation-grain quality signals: what the classifier predicted, whether
    a human agreed, and how (if) the conversation was escalated.

    One prediction per conversation is assumed; if the classifier ever emits
    several, the earliest is used and `n_predictions` exposes the count.
-#}
with conversations as (
    select * from {{ ref('stg_conversations') }}
),

predictions as (
    select
        *,
        row_number() over (partition by conversation_id order by predicted_at) as prediction_rank,
        count(*) over (partition by conversation_id)                            as n_predictions
    from {{ ref('stg_intent_predictions') }}
),

escalations as (
    select * from {{ ref('stg_escalations') }}
)

select
    c.conversation_id,
    c.initial_intent,
    c.resolution_status,
    c.is_escalated,
    c.is_auto_resolved,
    c.has_conflicting_resolution,
    c.satisfaction_score,
    c.has_satisfaction_score,

    -- intent classification
    p.prediction_id,
    p.predicted_intent,
    p.confidence,
    p.confidence_bucket,
    p.human_corrected_intent,
    p.is_human_reviewed,
    p.is_correct,
    p.is_corrected,
    p.n_predictions,
    p.predicted_intent = c.initial_intent                   as prediction_matches_initial_intent,

    -- escalation detail
    e.escalation_id,
    e.escalated_at,
    e.escalation_reason,
    e.handled_by_team,
    e.time_to_handoff_seconds,
    -- an "escalated" conversation without a hand-off record (or vice versa) is a pipeline gap
    c.is_escalated and e.escalation_id is null              as is_escalated_without_record,
    not c.is_escalated and e.escalation_id is not null      as has_record_without_escalation_flag
from conversations as c
left join predictions as p
    on c.conversation_id = p.conversation_id
    and p.prediction_rank = 1
left join escalations as e
    on c.conversation_id = e.conversation_id
