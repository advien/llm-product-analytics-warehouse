with catalog as (
    select * from {{ ref('model_catalog') }}
),

latest_price as (
    select
        model_name,
        arg_max(input_price_per_1k_tokens, price_date)      as current_input_price_per_1k_tokens,
        arg_max(output_price_per_1k_tokens, price_date)     as current_output_price_per_1k_tokens,
        count(distinct input_price_per_1k_tokens)           as n_input_price_changes,
        min(price_date)                                     as priced_from,
        max(price_date)                                     as priced_to
    from {{ ref('stg_daily_model_prices') }}
    group by 1
),

usage as (
    select
        model_name,
        count(*)                                            as n_requests,
        min(created_at)                                     as first_seen_at,
        max(created_at)                                     as last_seen_at,
        count(*) filter (where has_model_alias)             as n_requests_via_alias
    from {{ ref('stg_llm_requests') }}
    group by 1
)

select
    c.model_name,
    c.model_provider,
    c.model_tier,
    c.context_window_tokens,
    p.current_input_price_per_1k_tokens,
    p.current_output_price_per_1k_tokens,
    p.n_input_price_changes - 1                             as n_price_changes,
    p.priced_from,
    p.priced_to,
    coalesce(u.n_requests, 0)                               as n_requests,
    u.first_seen_at,
    u.last_seen_at,
    coalesce(u.n_requests_via_alias, 0)                     as n_requests_via_alias
from catalog as c
left join latest_price as p using (model_name)
left join usage as u using (model_name)
