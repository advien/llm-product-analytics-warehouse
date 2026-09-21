with users as (
    select * from {{ ref('stg_users') }}
),

activity as (
    select
        c.user_id,
        count(*)                                        as n_conversations,
        min(c.started_at)                               as first_conversation_at,
        max(c.started_at)                               as last_conversation_at,
        count(*) filter (where c.is_escalated)          as n_escalated_conversations,
        avg(c.satisfaction_score)                       as avg_satisfaction_score,
        sum(r.cost_usd)                                 as lifetime_llm_cost_usd
    from {{ ref('stg_conversations') }} as c
    left join {{ ref('int_conversation_request_rollup') }} as r using (conversation_id)
    group by 1
)

select
    u.user_id,
    u.created_at                                        as signup_at,
    u.signup_date,
    u.signup_week,
    u.country_code,
    u.segment,
    u.signup_channel,
    coalesce(a.n_conversations, 0)                      as n_conversations,
    a.first_conversation_at,
    a.last_conversation_at,
    coalesce(a.n_escalated_conversations, 0)            as n_escalated_conversations,
    a.avg_satisfaction_score,
    coalesce(a.lifetime_llm_cost_usd, 0)                as lifetime_llm_cost_usd,
    a.n_conversations is not null                       as has_used_assistant,
    datediff('day', u.signup_date, cast(a.first_conversation_at as date)) as days_to_first_conversation
from users as u
left join activity as a using (user_id)
