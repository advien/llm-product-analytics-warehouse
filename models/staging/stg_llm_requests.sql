{#-
    Cleaning rules (each one is flagged, never silently dropped):
      * duplicate request_id    -> keep the earliest-ingested copy
      * negative latency        -> latency_ms set to NULL, raw value preserved
      * total_tokens mismatch   -> recomputed as prompt + completion, raw value preserved
      * preview model aliases   -> mapped to canonical name via the model_aliases seed
      * missing conversation_id -> kept (cost is still real), flagged as orphan
      * late-arriving events    -> flagged when ingestion lags the event by > 1 hour
-#}
with source as (
    select * from {{ source('raw', 'raw_llm_requests') }}
),

typed as (
    select
        request_id,
        nullif(trim(conversation_id), '')           as conversation_id,
        cast(created_at as timestamp)               as created_at,
        cast(_ingested_at as timestamp)             as ingested_at,
        lower(trim(model_provider))                 as model_provider,
        trim(model_name)                            as model_name_raw,
        cast(prompt_tokens as integer)              as prompt_tokens,
        cast(completion_tokens as integer)          as completion_tokens,
        cast(total_tokens as integer)               as raw_total_tokens,
        cast(latency_ms as integer)                 as raw_latency_ms,
        cast(cost_usd as decimal(12, 6))            as recorded_cost_usd,
        lower(trim(status))                         as status,
        nullif(lower(trim(error_type)), '')         as error_type
    from source
),

deduplicated as (
    select
        *,
        row_number() over (partition by request_id order by ingested_at, created_at) as ingest_rank,
        count(*) over (partition by request_id)                                        as ingest_copies
    from typed
),

aliases as (
    select * from {{ ref('model_aliases') }}
)

select
    d.request_id,
    d.conversation_id,
    d.created_at,
    d.ingested_at,
    cast(d.created_at as date)                                  as request_date,
    d.model_provider,
    d.model_name_raw,
    coalesce(a.model_name_canonical, d.model_name_raw)          as model_name,
    d.prompt_tokens,
    d.completion_tokens,
    d.prompt_tokens + d.completion_tokens                       as total_tokens,
    d.raw_total_tokens,
    case when d.raw_latency_ms >= 0 then d.raw_latency_ms end   as latency_ms,
    d.raw_latency_ms,
    d.recorded_cost_usd,
    d.status,
    d.error_type,
    d.status = 'success'                                        as is_success,
    d.status in ('error', 'timeout', 'rate_limited')            as is_failed,

    -- data-quality flags
    d.conversation_id is null                                   as is_orphan,
    d.raw_latency_ms < 0                                        as has_invalid_latency,
    d.raw_total_tokens <> d.prompt_tokens + d.completion_tokens as has_token_sum_mismatch,
    a.model_name_alias is not null                              as has_model_alias,
    d.ingest_copies > 1                                         as had_duplicate_ingest,
    datediff('minute', d.created_at, d.ingested_at) > 60        as is_late_arriving,

    -- bucketing for dashboards
    case
        when d.prompt_tokens + d.completion_tokens < 500 then '0-499'
        when d.prompt_tokens + d.completion_tokens < 1000 then '500-999'
        when d.prompt_tokens + d.completion_tokens < 2000 then '1000-1999'
        when d.prompt_tokens + d.completion_tokens < 4000 then '2000-3999'
        else '4000+'
    end                                                         as token_bucket,
    case
        when d.raw_latency_ms < 0 then null
        when d.raw_latency_ms < 1000 then '<1s'
        when d.raw_latency_ms < 3000 then '1-3s'
        when d.raw_latency_ms < 6000 then '3-6s'
        when d.raw_latency_ms < 15000 then '6-15s'
        else '15s+'
    end                                                         as latency_bucket
from deduplicated as d
left join aliases as a
    on d.model_name_raw = a.model_name_alias
where d.ingest_rank = 1
