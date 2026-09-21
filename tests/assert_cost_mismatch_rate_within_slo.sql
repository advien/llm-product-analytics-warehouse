-- Operational SLO: on any given day, no more than 2% of requests may have a
-- logged cost that disagrees with the price-list recomputation. Individual
-- mismatches are expected (see warn_unreconciled_request_costs); a spike
-- means the orchestration service's price sheet drifted or a model was
-- shipped without a price row.
select
    metric_date,
    n_requests,
    n_cost_mismatches,
    n_cost_mismatches * 1.0 / n_requests as mismatch_rate
from {{ ref('fct_daily_product_metrics') }}
where n_requests > 0
  and n_cost_mismatches * 1.0 / n_requests > 0.02
