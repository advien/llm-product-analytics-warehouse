{#-
    Confusion matrix of the intent classifier, built ONLY from human-reviewed
    predictions (the only rows with a trustworthy label). Grain: one row per
    (actual_intent, predicted_intent) pair that occurred at least once.

    `share_of_actual` is the row-normalised recall view: of all conversations
    that were really X, what fraction did the model call Y.
-#}
with reviewed as (
    select
        human_corrected_intent      as actual_intent,
        predicted_intent,
        confidence
    from {{ ref('stg_intent_predictions') }}
    where is_human_reviewed
),

pairs as (
    select
        actual_intent,
        predicted_intent,
        count(*)                        as n_predictions,
        avg(confidence)                 as avg_confidence
    from reviewed
    group by 1, 2
),

totals as (
    select actual_intent, count(*) as n_actual
    from reviewed
    group by 1
)

select
    p.actual_intent,
    p.predicted_intent,
    p.actual_intent = p.predicted_intent        as is_correct,
    p.n_predictions,
    t.n_actual,
    p.n_predictions * 1.0 / t.n_actual          as share_of_actual,
    p.avg_confidence
from pairs as p
inner join totals as t using (actual_intent)
