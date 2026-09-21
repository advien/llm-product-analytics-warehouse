-- Overall intent accuracy must agree between the daily KPI mart and the
-- per-intent mart (both derive from the same human-reviewed subset).
with daily as (
    select sum(n_correct_predictions) * 1.0 / sum(n_reviewed_predictions) as acc
    from {{ ref('fct_daily_product_metrics') }}
),

by_intent as (
    select sum(n_correct_predictions) * 1.0 / sum(n_reviewed_predictions) as acc
    from {{ ref('mart_intent_quality') }}
)

select daily.acc as daily_accuracy, by_intent.acc as intent_mart_accuracy
from daily, by_intent
where abs(daily.acc - by_intent.acc) > 0.0001
