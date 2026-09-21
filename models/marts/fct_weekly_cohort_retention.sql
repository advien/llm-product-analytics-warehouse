{#-
    Weekly cohort retention of ASSISTANT USAGE. Grain: (signup_week, weeks_since_signup).

    Definitions
      cohort              users whose signup_date falls in a calendar week (Monday start)
                          that lies entirely inside the observed window. Users who signed
                          up before the window have no observable week 0 and are excluded.
      weeks_since_signup  floor(days between the USER's signup date and the conversation
                          date / 7): user-relative weeks, so week 0 is each user's first
                          7 days, not the calendar week of signup.
      retained            user started >= 1 conversation in that week.
      retention_rate      retained users / cohort size (unbounded retention: a user
                          inactive in week 2 but active in week 3 counts in week 3).
      is_fully_observable the whole week N has elapsed for EVERY user in the cohort
                          (last signup day in cohort + 7*(N+1) days <= window end).
                          Partially observable cells are kept, flagged, and biased low.

    What this is NOT: app-login retention. The warehouse only sees conversations
    with the assistant, so this measures whether users keep coming back to the
    assistant, which for a support product is a mixed signal (see docs).
-#}
with bounds as (
    select
        min(conversation_date) as window_start,
        max(conversation_date) as window_end
    from {{ ref('stg_conversations') }}
),

cohort_users as (
    select
        u.user_id,
        u.signup_date,
        u.signup_week,
        u.segment,
        u.signup_channel
    from {{ ref('stg_users') }} as u
    cross join bounds as b
    where u.signup_week >= b.window_start                       -- whole signup week inside the window
      and u.signup_week + interval 6 day <= b.window_end
),

cohorts as (
    select
        signup_week,
        count(*)            as cohort_size,
        max(signup_date)    as last_signup_date
    from cohort_users
    group by 1
),

-- one row per (cohort, week N) for every N that at least started inside the window
spine as (
    select
        c.signup_week,
        c.cohort_size,
        c.last_signup_date,
        n.weeks_since_signup
    from cohorts as c
    cross join bounds as b
    cross join (
        select unnest(range(0, 53)) as weeks_since_signup
    ) as n
    where c.signup_week + n.weeks_since_signup * interval 7 day <= b.window_end
),

activity as (
    select
        cu.signup_week,
        cast(floor(datediff('day', cu.signup_date, c.conversation_date) / 7.0) as integer) as weeks_since_signup,
        count(distinct cu.user_id)                                  as n_retained_users,
        count(*)                                                    as n_conversations,
        count(*) filter (where c.is_escalated)                      as n_escalated_conversations
    from cohort_users as cu
    inner join {{ ref('stg_conversations') }} as c
        on cu.user_id = c.user_id
       and c.conversation_date >= cu.signup_date
    group by 1, 2
)

select
    s.signup_week,
    s.weeks_since_signup,
    s.cohort_size,
    coalesce(a.n_retained_users, 0)                                 as n_retained_users,
    coalesce(a.n_retained_users, 0) * 1.0 / s.cohort_size           as retention_rate,
    coalesce(a.n_conversations, 0)                                  as n_conversations,
    coalesce(a.n_conversations, 0) * 1.0 / s.cohort_size            as conversations_per_cohort_user,
    coalesce(a.n_escalated_conversations, 0)                        as n_escalated_conversations,
    s.last_signup_date + (s.weeks_since_signup + 1) * interval 7 day - interval 1 day
                                                                    as week_fully_elapsed_on,
    s.last_signup_date + (s.weeks_since_signup + 1) * interval 7 day - interval 1 day
        <= b.window_end                                             as is_fully_observable
from spine as s
cross join bounds as b
left join activity as a
    on s.signup_week = a.signup_week
   and s.weeks_since_signup = a.weeks_since_signup
