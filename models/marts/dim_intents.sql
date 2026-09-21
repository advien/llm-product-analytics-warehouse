with catalog as (
    select * from {{ ref('intent_catalog') }}
),

observed as (
    select
        initial_intent                                      as intent,
        count(*)                                            as n_conversations,
        min(started_at)                                     as first_seen_at,
        max(started_at)                                     as last_seen_at
    from {{ ref('stg_conversations') }}
    group by 1
)

select
    c.intent,
    c.intent_category,
    c.risk_level,
    c.requires_human_policy,
    c.description,
    coalesce(o.n_conversations, 0)                          as n_conversations,
    o.first_seen_at,
    o.last_seen_at
from catalog as c
left join observed as o using (intent)
