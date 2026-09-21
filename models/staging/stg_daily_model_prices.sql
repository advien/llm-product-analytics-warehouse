with source as (
    select * from {{ source('raw', 'raw_daily_model_prices') }}
)

select
    cast(price_date as date)                            as price_date,
    lower(trim(model_provider))                         as model_provider,
    trim(model_name)                                    as model_name,
    cast(input_price_per_1k_tokens as decimal(12, 8))   as input_price_per_1k_tokens,
    cast(output_price_per_1k_tokens as decimal(12, 8))  as output_price_per_1k_tokens
from source
