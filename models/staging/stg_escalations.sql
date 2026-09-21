with source as (
    select * from {{ source('raw', 'raw_escalations') }}
)

select
    escalation_id,
    conversation_id,
    cast(created_at as timestamp)               as escalated_at,
    lower(trim(reason))                         as escalation_reason,
    lower(trim(handled_by_team))                as handled_by_team,
    cast(time_to_handoff_seconds as integer)    as time_to_handoff_seconds
from source
