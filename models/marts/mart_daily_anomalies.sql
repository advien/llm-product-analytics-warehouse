{#-
    Daily anomaly flags on the core product / reliability / cost metrics.
    Grain: (metric_date, metric_name) - long format so a dashboard or an
    alerting job can filter on `is_anomaly` without knowing the metric list.

    Method: robust z-score against a trailing baseline.
      baseline   = median of the previous {{ var('anomaly_baseline_days', 14) }} days (current day excluded)
      spread     = MAD of the same window, scaled by 1.4826 to be sigma-comparable
      z          = (value - baseline) / spread
      is_anomaly = |z| > {{ var('anomaly_z_threshold', 3.5) }}  and  >= {{ var('anomaly_min_history_days', 7) }} days of history

    Median/MAD rather than mean/stddev so that one incident day does not
    inflate the baseline for the following two weeks.

    Each metric declares a KIND, which sets the baseline window and the floor
    on the spread (MAD alone under-estimates noise on small counts and on
    naturally jittery percentiles, and cannot see weekly seasonality):
      rate     trailing window, spread floor  2% of baseline
      latency  trailing window, spread floor  5% of baseline
      count    trailing window, spread floor  sqrt(baseline)   (Poisson noise)
      amount   same-weekday window over the previous 8 weeks (weekly
               seasonality: weekend spend is ~35% lower), floor 5%
    `direction` says which side the metric moved to; `actionable_direction`
    says which side matters, so a dashboard can show only what needs action.
-#}
{% set metrics = [
    ('error_rate',                   'high', 'rate'),
    ('timeout_rate',                 'high', 'rate'),
    ('p95_latency_ms',               'high', 'latency'),
    ('escalation_rate',              'high', 'rate'),
    ('llm_failure_escalation_share', 'high', 'rate'),
    ('n_llm_failure_escalations',    'high', 'count'),
    ('cost_per_conversation_usd',    'high', 'rate'),
    ('total_cost_usd',               'high', 'amount'),
    ('auto_resolution_rate',         'low',  'rate'),
    ('avg_satisfaction_score',       'low',  'rate'),
    ('intent_accuracy',              'low',  'rate'),
] %}

with daily as (
    select * from {{ ref('fct_daily_product_metrics') }}
    where not is_partial_day
),

long as (
    {% for metric, bad_side, kind in metrics %}
    select
        metric_date,
        '{{ metric }}'                          as metric_name,
        '{{ bad_side }}'                        as actionable_direction,
        '{{ kind }}'                            as metric_kind,
        cast({{ metric }} as double)            as metric_value
    from daily
    {% if not loop.last %}union all{% endif %}
    {% endfor %}
),

with_baseline as (
    select
        metric_date,
        metric_name,
        actionable_direction,
        metric_kind,
        metric_value,
        case metric_kind
            when 'amount' then median(metric_value) over w_weekly
            else median(metric_value) over w_trailing
        end                                     as baseline_value,
        case metric_kind
            when 'amount' then mad(metric_value) over w_weekly
            else mad(metric_value) over w_trailing
        end                                     as baseline_mad,
        case metric_kind
            when 'amount' then count(metric_value) over w_weekly
            else count(metric_value) over w_trailing
        end                                     as n_history_days,
        case metric_kind
            when 'amount' then {{ var('anomaly_min_history_weeks', 4) }}
            else {{ var('anomaly_min_history_days', 7) }}
        end                                     as min_history_days
    from long
    window
        w_trailing as (
            partition by metric_name
            order by metric_date
            rows between {{ var('anomaly_baseline_days', 14) }} preceding and 1 preceding
        ),
        w_weekly as (
            partition by metric_name, dayofweek(metric_date)
            order by metric_date
            rows between {{ var('anomaly_baseline_weeks', 8) }} preceding and 1 preceding
        )
),

scored as (
    select
        *,
        greatest(
            1.4826 * baseline_mad,
            case metric_kind
                when 'rate'    then 0.02 * abs(baseline_value)
                when 'latency' then 0.05 * abs(baseline_value)
                when 'count'   then sqrt(greatest(baseline_value, 1))
                when 'amount'  then 0.05 * abs(baseline_value)
            end,
            1e-9
        )                                       as baseline_spread
    from with_baseline
),

z as (
    select
        *,
        (metric_value - baseline_value) / baseline_spread as robust_z
    from scored
)

select
    metric_date,
    metric_name,
    metric_kind,
    metric_value,
    baseline_value,
    baseline_spread,
    n_history_days,
    case when n_history_days >= min_history_days then robust_z end                          as robust_z,
    case
        when metric_value > baseline_value then 'high'
        when metric_value < baseline_value then 'low'
    end                                                                                     as direction,
    actionable_direction,
    n_history_days >= min_history_days
        and abs(robust_z) > {{ var('anomaly_z_threshold', 3.5) }}                            as is_anomaly,
    n_history_days >= min_history_days
        and abs(robust_z) > {{ var('anomaly_z_threshold', 3.5) }}
        and (case when metric_value > baseline_value then 'high' else 'low' end) = actionable_direction
                                                                                            as is_actionable_anomaly
from z
