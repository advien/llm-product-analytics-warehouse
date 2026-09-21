{#-
    Reliability view per model per day for the on-call / model-ops dashboard.
    Grain: (request_date, model_provider, model_name). Latency percentiles
    exclude requests with invalid raw latency (NULL after staging).
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
    count(*) filter (where is_failed)                               as n_failed_requests,
    count(*) filter (where status = 'error')                        as n_error_requests,
    count(*) filter (where status = 'timeout')                      as n_timeout_requests,
    count(*) filter (where status = 'rate_limited')                 as n_rate_limited_requests,
    count(*) filter (where error_type = 'provider_5xx')             as n_provider_5xx,
    count(*) filter (where error_type = 'content_filter')           as n_content_filter,
    count(*) filter (where error_type = 'context_length')           as n_context_length,
    count(*) filter (where error_type = 'invalid_request')          as n_invalid_request,
    count(*) filter (where is_failed) * 1.0 / count(*)              as error_rate,
    count(*) filter (where status = 'timeout') * 1.0 / count(*)     as timeout_rate,
    count(latency_ms)                                               as n_latency_samples,
    avg(latency_ms)                                                 as avg_latency_ms,
    quantile_cont(latency_ms, 0.50)                                 as p50_latency_ms,
    quantile_cont(latency_ms, 0.95)                                 as p95_latency_ms,
    quantile_cont(latency_ms, 0.99)                                 as p99_latency_ms,
    -- latency of successful requests only: what a user actually waited for an answer
    quantile_cont(latency_ms, 0.95) filter (where is_success)       as p95_success_latency_ms,
    avg(completion_tokens) filter (where is_success)                as avg_completion_tokens,
    sum(cost_usd)                                                   as total_cost_usd,
    count(*) filter (where has_invalid_latency)                     as n_invalid_latency_rows
from requests
group by 1, 2, 3, 4
