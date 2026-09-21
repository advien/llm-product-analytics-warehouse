-- Every date with at least one LLM request must appear in the daily KPI mart.
select r.request_date, count(*) as n_requests
from {{ ref('fct_llm_requests') }} as r
left join {{ ref('fct_daily_product_metrics') }} as d
    on r.request_date = d.metric_date
where d.metric_date is null
group by 1
