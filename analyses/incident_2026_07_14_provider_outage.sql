-- Ad-hoc investigation: what happened on 2026-07-14?
-- The daily KPI mart shows error rate 4.6% -> 19% and p95 latency 6.5s -> 43s.
-- This query attributes the spike to a provider and quantifies the blast
-- radius in conversations, escalations and wasted spend.
-- Run with: dbt compile --select incident_2026_07_14_provider_outage, then
-- execute target/compiled/.../incident_2026_07_14_provider_outage.sql

with by_provider as (
    select
        request_date,
        model_provider,
        sum(n_requests)                                     as n_requests,
        sum(n_failed_requests) * 1.0 / sum(n_requests)      as error_rate,
        max(p95_latency_ms)                                 as worst_model_p95_ms,
        sum(n_provider_5xx)                                 as n_provider_5xx,
        sum(n_timeout_requests)                             as n_timeouts
    from {{ ref('mart_model_reliability_daily') }}
    where request_date between date '2026-07-13' and date '2026-07-15'
    group by 1, 2
),

blast_radius as (
    select
        conversation_date,
        count(*)                                            as conversations,
        count(*) filter (where had_failed_request)          as conversations_with_failure,
        count(*) filter (where is_escalated
                           and escalation_reason = 'llm_failure') as escalations_due_to_llm_failure,
        round(sum(cost_usd) filter (where had_failed_request), 2) as cost_of_affected_conversations_usd
    from {{ ref('fct_conversations') }}
    where conversation_date between date '2026-07-13' and date '2026-07-15'
    group by 1
)

select
    p.request_date,
    p.model_provider,
    p.n_requests,
    round(p.error_rate, 3)          as error_rate,
    p.worst_model_p95_ms,
    p.n_provider_5xx,
    p.n_timeouts,
    b.conversations,
    b.conversations_with_failure,
    b.escalations_due_to_llm_failure,
    b.cost_of_affected_conversations_usd
from by_provider as p
left join blast_radius as b
    on p.request_date = b.conversation_date
order by p.request_date, p.error_rate desc
