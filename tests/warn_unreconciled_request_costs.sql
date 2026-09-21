{{ config(severity = 'warn') }}

-- Lists every request whose logged cost is outside tolerance of the
-- recomputed cost. Expected to WARN on the synthetic data (the generator
-- injects a lagging price sheet for three models); the point is visibility,
-- not a hard stop - marts use the recomputed cost regardless.
select
    request_id,
    request_date,
    model_name,
    logged_cost_usd,
    cost_usd        as calculated_cost_usd,
    cost_delta_pct
from {{ ref('fct_llm_requests') }}
where not is_cost_reconciled
