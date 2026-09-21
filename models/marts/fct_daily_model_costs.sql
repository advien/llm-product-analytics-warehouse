{#-
    Daily cost ledger per model. Grain: (request_date, model_provider,
    model_name). Includes orphan requests: the provider bills for them
    regardless of whether the conversation link survived.

    `total_cost_usd` here must reconcile with fct_daily_product_metrics
    (test: daily_cost_reconciles_between_marts).
-#}
with requests as (
    select * from {{ ref('fct_llm_requests') }}
)

select
    request_date,
    model_provider,
    model_name,
    model_tier,
    count(*)                                                        as n_requests,
    count(*) filter (where is_success)                              as n_successful_requests,
    count(*) filter (where is_failed)                               as n_failed_requests,
    sum(prompt_tokens)                                              as prompt_tokens,
    sum(completion_tokens)                                          as completion_tokens,
    sum(total_tokens)                                               as total_tokens,
    sum(cost_usd)                                                   as total_cost_usd,
    sum(logged_cost_usd)                                            as total_logged_cost_usd,
    sum(cost_usd) - sum(logged_cost_usd)                            as cost_reconciliation_delta_usd,
    count(*) filter (where not is_cost_reconciled)                  as n_cost_mismatches,
    sum(cost_usd) / nullif(count(*), 0)                             as cost_per_request_usd,
    sum(cost_usd) / nullif(sum(total_tokens), 0) * 1000             as cost_per_1k_tokens_usd,
    sum(cost_usd) filter (where is_failed)                          as wasted_cost_on_failures_usd,
    arg_max(input_price_per_1k_tokens, request_date)                as input_price_per_1k_tokens,
    arg_max(output_price_per_1k_tokens, request_date)               as output_price_per_1k_tokens
from requests
group by 1, 2, 3, 4
