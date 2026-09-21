-- Daily LLM cost must be identical whether you read it from the product KPI
-- mart or sum the per-model ledger. A difference means one mart is dropping or
-- double-counting requests (e.g. a calendar that misses late-night requests).
with product as (
    select metric_date as d, total_cost_usd as product_cost
    from {{ ref('fct_daily_product_metrics') }}
),

ledger as (
    select request_date as d, sum(total_cost_usd) as ledger_cost
    from {{ ref('fct_daily_model_costs') }}
    group by 1
)

select
    coalesce(p.d, l.d)                              as metric_date,
    p.product_cost,
    l.ledger_cost,
    coalesce(p.product_cost, 0) - coalesce(l.ledger_cost, 0) as delta_usd
from product as p
full outer join ledger as l using (d)
where abs(coalesce(p.product_cost, 0) - coalesce(l.ledger_cost, 0)) > 0.0001
