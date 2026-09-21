-- Cost attributed to conversations must equal the cost of all non-orphan
-- requests. Guards against join fan-out in the conversation rollup.
with conv as (
    select sum(cost_usd) as conversation_cost
    from {{ ref('fct_conversations') }}
),

req as (
    select sum(cost_usd) as request_cost
    from {{ ref('fct_llm_requests') }}
    where not is_orphan
)

select conversation_cost, request_cost, conversation_cost - request_cost as delta_usd
from conv, req
where abs(conversation_cost - request_cost) > 0.0001
