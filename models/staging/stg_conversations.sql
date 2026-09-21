{#-
    Resolution logic. The raw feed carries two independent booleans that can
    contradict each other (both true). An escalation is the stronger, externally
    observable signal (a human team received the hand-off), so when both are set
    the conversation is treated as escalated and the conflict is flagged rather
    than silently overwritten.
-#}
with source as (
    select * from {{ source('raw', 'raw_conversations') }}
),

typed as (
    select
        conversation_id,
        user_id,
        cast(started_at as timestamp)                           as started_at,
        cast(ended_at as timestamp)                             as ended_at,
        lower(trim(channel))                                    as channel,
        lower(trim(initial_intent))                             as initial_intent,
        cast(resolved_without_escalation as boolean)            as raw_resolved_without_escalation,
        cast(escalated as boolean)                              as raw_escalated,
        cast(nullif(satisfaction_score, '') as decimal(3, 1))   as satisfaction_score
    from source
)

select
    conversation_id,
    user_id,
    started_at,
    ended_at,
    cast(started_at as date)                                as conversation_date,
    datediff('second', started_at, ended_at)                as duration_seconds,
    channel,
    initial_intent,
    raw_escalated                                           as is_escalated,
    raw_resolved_without_escalation and not raw_escalated   as is_auto_resolved,
    case
        when raw_escalated then 'escalated'
        when raw_resolved_without_escalation then 'auto_resolved'
        else 'abandoned'
    end                                                     as resolution_status,
    raw_resolved_without_escalation and raw_escalated       as has_conflicting_resolution,
    cast(satisfaction_score as integer)                     as satisfaction_score,
    satisfaction_score is not null                          as has_satisfaction_score
from typed
