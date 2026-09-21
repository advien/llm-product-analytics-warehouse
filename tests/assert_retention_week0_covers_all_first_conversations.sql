-- Sanity check on the cohort spine: every eligible user who had at least one
-- conversation in their first 7 days must be counted in week 0 of their
-- cohort. Compares the mart against an independent recomputation.
with recomputed as (
    select
        u.signup_week,
        count(distinct u.user_id) as n_week0_users
    from {{ ref('dim_users') }} as u
    inner join {{ ref('fct_conversations') }} as c
        on u.user_id = c.user_id
       and c.conversation_date between u.signup_date and u.signup_date + interval 6 day
    group by 1
),

mart as (
    select signup_week, n_retained_users
    from {{ ref('fct_weekly_cohort_retention') }}
    where weeks_since_signup = 0
)

select m.signup_week, m.n_retained_users, r.n_week0_users
from mart as m
left join recomputed as r using (signup_week)
where m.n_retained_users <> coalesce(r.n_week0_users, 0)
