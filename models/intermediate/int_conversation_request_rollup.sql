{#-
    Conversation-grain aggregation of LLM requests.

    Orphan requests (no conversation_id) are excluded here by construction; they
    still count in fct_llm_requests and fct_daily_model_costs so that the cost
    ledger stays complete.

    Cost uses the recalculated `calculated_cost_usd` (tokens x price list), not
    the logged value, so conversation economics are not distorted by stale-price
    logging. Latency aggregates ignore NULLs (rows with invalid raw latency).
-#}
with requests as (
    select * from {{ ref('stg_llm_requests') }}
    where conversation_id is not null
),

costs as (
    select request_id, calculated_cost_usd, recorded_cost_usd
    from {{ ref('int_model_costs') }}
),

joined as (
    select
        r.*,
        c.calculated_cost_usd,
        c.recorded_cost_usd as logged_cost_usd
    from requests as r
    inner join costs as c using (request_id)
),

first_last as (
    select
        conversation_id,
        min(created_at)                                                                 as first_request_at,
        max(created_at)                                                                 as last_request_at,
        arg_min(model_name, created_at)                                                 as first_model_name,
        arg_max(model_name, created_at)                                                 as last_model_name
    from joined
    group by 1
)

select
    j.conversation_id,
    count(*)                                                        as n_requests,
    count(*) filter (where j.is_success)                            as n_successful_requests,
    count(*) filter (where j.is_failed)                             as n_failed_requests,
    count(*) filter (where j.status = 'error')                      as n_error_requests,
    count(*) filter (where j.status = 'timeout')                    as n_timeout_requests,
    count(*) filter (where j.status = 'rate_limited')               as n_rate_limited_requests,
    count(distinct j.model_name)                                    as n_distinct_models,
    count(distinct j.model_provider)                                 as n_distinct_providers,
    sum(j.prompt_tokens)                                            as prompt_tokens,
    sum(j.completion_tokens)                                        as completion_tokens,
    sum(j.total_tokens)                                             as total_tokens,
    sum(j.calculated_cost_usd)                                      as cost_usd,
    sum(j.logged_cost_usd)                                          as logged_cost_usd,
    avg(j.latency_ms)                                               as avg_latency_ms,
    max(j.latency_ms)                                               as max_latency_ms,
    sum(j.latency_ms)                                               as total_latency_ms,
    bool_or(j.is_failed)                                            as had_failed_request,
    bool_or(j.has_invalid_latency or j.has_token_sum_mismatch
            or j.has_model_alias or j.had_duplicate_ingest)         as had_data_quality_issue,
    fl.first_request_at,
    fl.last_request_at,
    fl.first_model_name,
    fl.last_model_name
from joined as j
inner join first_last as fl using (conversation_id)
group by
    j.conversation_id,
    fl.first_request_at, fl.last_request_at, fl.first_model_name, fl.last_model_name
