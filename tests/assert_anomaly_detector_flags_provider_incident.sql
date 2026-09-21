-- Regression fixture for the anomaly detector. The synthetic generator plants
-- a provider incident on day 42 of the window (2026-07-14 with the default
-- end date). The detector must flag error_rate, timeout_rate and p95 latency
-- on that day, and must NOT flag error_rate on more than 1 other day in the
-- window (precision guard - a detector that fires everywhere is useless).
--
-- NOTE: this test encodes a property of the synthetic dataset, not a
-- business invariant. Regenerating with --days or --end-date changes the
-- incident date; set var incident_date accordingly.
{% set incident_date = var('incident_date', '2026-07-14') %}

with expected as (
    select unnest(['error_rate', 'timeout_rate', 'p95_latency_ms']) as metric_name
),

missed as (
    select e.metric_name, 'incident day not flagged' as problem
    from expected as e
    left join {{ ref('mart_daily_anomalies') }} as a
        on a.metric_name = e.metric_name
        and a.metric_date = date '{{ incident_date }}'
        and a.is_actionable_anomaly
    where a.metric_name is null
),

noisy as (
    select 'error_rate' as metric_name, 'flagged on ' || count(*) || ' non-incident days' as problem
    from {{ ref('mart_daily_anomalies') }}
    where metric_name = 'error_rate'
      and is_anomaly
      and metric_date <> date '{{ incident_date }}'
    having count(*) > 1
)

select * from missed
union all
select * from noisy
