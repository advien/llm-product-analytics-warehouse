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

    Each metric declares a KIND, which sets the baseline window and a FLOOR on
    the spread. MAD alone under-estimates day-to-day sampling noise (and can
    be ~0 on a stable series), so the floor is the metric's own statistical
    noise at the day's volume:
      proportion  trailing window; floor = sqrt(p(1-p)/n), the binomial
                  standard error at the DAY's denominator n. A 3.5 sigma flag
                  therefore means "beyond sampling noise", and the detector is
                  automatically stricter on high-volume days.
      score       trailing window; floor 2% of baseline (a 1-5 mean rated by
                  ~300 users/day has s.e. ~0.06 ~ 2% of 3.5)
      ratio       trailing window; floor 5% of baseline (p95 latency, unit
                  cost - heavy-tailed ratios that jitter a few % daily)
      count       trailing window; floor sqrt(baseline) (Poisson)
      amount      same-weekday window over the previous 4 weeks (weekly
                  seasonality; a longer window lags the volume trend), floor 10%
                  (measured robust day-to-day spread of daily spend is ~11%)
    `direction` says which side the metric moved to; `actionable_direction`
    says which side matters, so a dashboard can show only what needs action.
-#}
{#- (metric, bad direction, kind, denominator column for proportions) -#}
{% set metrics = [
    ('error_rate',                   'high', 'proportion', 'n_requests'),
    ('timeout_rate',                 'high', 'proportion', 'n_requests'),
    ('p95_latency_ms',               'high', 'ratio',      'null'),
    ('escalation_rate',              'high', 'proportion', 'n_conversations'),
    ('llm_failure_escalation_share', 'high', 'proportion', 'n_escalated'),
    ('n_llm_failure_escalations',    'high', 'count',      'null'),
    ('cost_per_conversation_usd',    'high', 'ratio',      'null'),
    ('total_cost_usd',               'high', 'amount',     'null'),
    ('auto_resolution_rate',         'low',  'proportion', 'n_conversations'),
    ('avg_satisfaction_score',       'low',  'score',      'n_rated'),
    ('intent_accuracy',              'low',  'proportion', 'n_reviewed_predictions'),
] %}

with daily as (
    select * from {{ ref('fct_daily_product_metrics') }}
    where not is_partial_day
),

long as (
    {% for metric, bad_side, kind, denominator in metrics %}
    select
        metric_date,
        '{{ metric }}'                          as metric_name,
        '{{ bad_side }}'                        as actionable_direction,
        '{{ kind }}'                            as metric_kind,
        cast({{ metric }} as double)            as metric_value,
        cast({{ denominator }} as double)       as denominator
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
        denominator,
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
            when 'amount' then {{ var('anomaly_min_history_weeks', 3) }}
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
            rows between {{ var('anomaly_baseline_weeks', 4) }} preceding and 1 preceding
        )
),

scored as (
    select
        *,
        greatest(
            1.4826 * baseline_mad,
            case metric_kind
                when 'proportion' then sqrt(least(greatest(baseline_value, 1e-6), 1 - 1e-6)
                                            * (1 - least(greatest(baseline_value, 1e-6), 1 - 1e-6))
                                            / greatest(denominator, 1))
                when 'score'      then 0.02 * abs(baseline_value)
                when 'ratio'      then 0.05 * abs(baseline_value)
                when 'count'      then sqrt(greatest(baseline_value, 1))
                when 'amount'     then 0.10 * abs(baseline_value)
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
    denominator,
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
