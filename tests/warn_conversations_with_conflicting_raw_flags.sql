{{ config(severity = 'warn') }}

-- Conversations whose raw feed said BOTH "resolved without escalation" and
-- "escalated". Staging resolves them to `escalated` (the hand-off record is
-- the stronger signal). Expected to WARN; tracked so the upstream team can fix
-- the double-write.
select conversation_id, started_at, initial_intent, resolution_status
from {{ ref('fct_conversations') }}
where has_conflicting_resolution
