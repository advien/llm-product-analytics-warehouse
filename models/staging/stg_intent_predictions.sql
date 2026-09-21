with source as (
    select * from {{ source('raw', 'raw_intent_predictions') }}
),

typed as (
    select
        prediction_id,
        conversation_id,
        cast(created_at as timestamp)                       as predicted_at,
        lower(trim(predicted_intent))                       as predicted_intent,
        cast(confidence as decimal(5, 3))                   as confidence,
        nullif(lower(trim(human_corrected_intent)), '')     as human_corrected_intent,
        cast(nullif(is_correct, '') as boolean)             as is_correct
    from source
)

select
    prediction_id,
    conversation_id,
    predicted_at,
    predicted_intent,
    confidence,
    human_corrected_intent,
    is_correct,
    human_corrected_intent is not null                      as is_human_reviewed,
    -- a review that disagrees with the model is a "correction"
    human_corrected_intent is not null
        and human_corrected_intent <> predicted_intent      as is_corrected,
    case
        when confidence >= 0.9 then '0.90-1.00'
        when confidence >= 0.8 then '0.80-0.89'
        when confidence >= 0.7 then '0.70-0.79'
        when confidence >= 0.5 then '0.50-0.69'
        else '<0.50'
    end                                                     as confidence_bucket
from typed
