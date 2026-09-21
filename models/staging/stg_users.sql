with source as (
    select * from {{ source('raw', 'raw_users') }}
)

select
    user_id,
    cast(created_at as timestamp)                   as created_at,
    cast(created_at as date)                        as signup_date,
    date_trunc('week', cast(created_at as date))    as signup_week,
    upper(trim(country))                            as country_code,
    lower(trim(segment))                            as segment,
    lower(trim(signup_channel))                     as signup_channel
from source
