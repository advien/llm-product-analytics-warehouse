{#-
    One row per LLM request (deduplicated), enriched with reconciled cost and
    conversation context. Orphan requests are kept with NULL conversation
    attributes so the cost ledger is complete.
-#}
with requests as (
    select * from {{ ref('stg_llm_requests') }}
),

costs as (
    select
        request_id,
        input_price_per_1k_tokens,
        output_price_per_1k_tokens,
        calculated_cost_usd,
        cost_delta_usd,
        cost_delta_pct,
        is_cost_reconciled
    from {{ ref('int_model_costs') }}
),

conversations as (
    select conversation_id, user_id, channel, initial_intent, resolution_status
    from {{ ref('stg_conversations') }}
),

models as (
    select model_name, model_tier from {{ ref('model_catalog') }}
)

select
    r.request_id,
    r.conversation_id,
    c.user_id,
    r.created_at,
    r.ingested_at,
    r.request_date,
    c.channel,
    c.initial_intent,
    c.resolution_status                                 as conversation_resolution_status,

    r.model_provider,
    r.model_name,
    m.model_tier,
    r.model_name_raw,
    r.status,
    r.error_type,
    r.is_success,
    r.is_failed,

    r.prompt_tokens,
    r.completion_tokens,
    r.total_tokens,
    r.token_bucket,
    r.latency_ms,
    r.latency_bucket,

    k.input_price_per_1k_tokens,
    k.output_price_per_1k_tokens,
    k.calculated_cost_usd                               as cost_usd,
    r.recorded_cost_usd                                 as logged_cost_usd,
    k.cost_delta_usd,
    k.cost_delta_pct,
    k.is_cost_reconciled,

    -- data-quality lineage
    r.is_orphan,
    r.has_invalid_latency,
    r.has_token_sum_mismatch,
    r.has_model_alias,
    r.had_duplicate_ingest,
    r.is_late_arriving
from requests as r
inner join costs as k using (request_id)
left join conversations as c using (conversation_id)
left join models as m using (model_name)
