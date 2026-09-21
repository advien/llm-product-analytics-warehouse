-- Every cohort's size must equal the number of users in dim_users with that
-- signup week (guards the cohort eligibility filter against silently dropping
-- or duplicating users).
with cohorts as (
    select distinct signup_week, cohort_size
    from {{ ref('fct_weekly_cohort_retention') }}
),

users as (
    select signup_week, count(*) as n_users
    from {{ ref('dim_users') }}
    group by 1
)

select c.signup_week, c.cohort_size, u.n_users
from cohorts as c
left join users as u using (signup_week)
where c.cohort_size <> coalesce(u.n_users, 0)
