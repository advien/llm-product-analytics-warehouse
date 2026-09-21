{#-
    Request-grain cost reconciliation.

    `recorded_cost_usd` is what the orchestration service logged at call time.
    `calculated_cost_usd` is recomputed here from token counts and the price
    list valid on the request date. The two disagree when the orchestration
    service priced the call with its own (lagging) price sheet - that is the
    drift the `assert_cost_mismatch_rate_within_slo` and
    `warn_unreconciled_request_costs` tests guard.

    Tolerance: 0.5% relative OR $0.00001 absolute, whichever is larger, so the
    6-decimal rounding of sub-cent requests does not trip the check.
-#}
with requests as (
    select * from {{ ref('stg_llm_requests') }}
),

prices as (
    select * from {{ ref('stg_daily_model_prices') }}
),

joined as (
    select
        r.request_id,
        r.conversation_id,
        r.request_date,
        r.model_provider,
        r.model_name,
        r.prompt_tokens,
        r.completion_tokens,
        r.total_tokens,
        r.recorded_cost_usd,
        p.input_price_per_1k_tokens,
        p.output_price_per_1k_tokens,
        cast(
            (r.prompt_tokens * p.input_price_per_1k_tokens
             + r.completion_tokens * p.output_price_per_1k_tokens) / 1000.0
            as decimal(12, 6)
        )                                                   as calculated_cost_usd
    from requests as r
    left join prices as p
        on r.model_name = p.model_name
        and r.request_date = p.price_date
)

select
    *,
    input_price_per_1k_tokens is null                       as is_missing_price,
    recorded_cost_usd - calculated_cost_usd                 as cost_delta_usd,
    case
        when calculated_cost_usd > 0
            then (recorded_cost_usd - calculated_cost_usd) / calculated_cost_usd
    end                                                     as cost_delta_pct,
    abs(recorded_cost_usd - calculated_cost_usd)
        <= greatest(0.005 * calculated_cost_usd, 0.00001)    as is_cost_reconciled
from joined
