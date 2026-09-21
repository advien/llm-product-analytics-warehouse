"""Generate synthetic raw event data for an LLM-powered financial support assistant.

Produces six CSV tables in data/raw/ that mimic what a product backend would
emit: users, conversations, LLM requests, intent predictions, escalations and a
daily model price list. The data is fully synthetic (no real users), seeded and
deterministic.

A configurable share of records is intentionally corrupted (see MESSY_RATES) so
the dbt layers have real data-quality problems to detect, quarantine and
document. Every corruption is tagged in data/raw/_messy_manifest.csv so the
tests can be reconciled against ground truth.

Usage:
    python scripts/generate_synthetic_data.py [--seed 42] [--days 90] [--users 6000]
"""

from __future__ import annotations

import argparse
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
import pandas as pd

RAW_DIR = Path(__file__).resolve().parents[1] / "data" / "raw"

# --------------------------------------------------------------------------- #
# Reference catalogues
# --------------------------------------------------------------------------- #

COUNTRIES = {"ES": 0.28, "NL": 0.18, "DE": 0.16, "SE": 0.12, "RS": 0.10, "PL": 0.09, "PT": 0.07}
SEGMENTS = {"retail": 0.72, "premium": 0.18, "business": 0.10}
SIGNUP_CHANNELS = {"organic": 0.40, "paid_social": 0.25, "referral": 0.20, "partner": 0.15}
CHANNELS = {"mobile_app": 0.62, "web": 0.30, "whatsapp": 0.08}

# intent -> (share, base escalation prob, base satisfaction mean)
INTENTS = {
    "balance_inquiry":      (0.16, 0.03, 4.4),
    "transaction_dispute":  (0.11, 0.42, 3.2),
    "card_block":           (0.09, 0.12, 4.0),
    "card_delivery":        (0.07, 0.18, 3.7),
    "payment_failed":       (0.10, 0.30, 3.3),
    "transfer_status":      (0.10, 0.15, 3.9),
    "account_verification": (0.08, 0.35, 3.4),
    "loan_inquiry":         (0.05, 0.25, 3.8),
    "fee_question":         (0.07, 0.08, 4.1),
    "app_login_issue":      (0.08, 0.22, 3.5),
    "limits_change":        (0.05, 0.20, 3.8),
    "general_question":     (0.04, 0.05, 4.2),
}

# provider, model, routing tier, (input, output) price per 1k tokens, latency (ms) lognormal params
MODELS = [
    ("openai",    "gpt-4o-mini",         "fast",    0.00015, 0.00060, (6.3, 0.35)),
    ("openai",    "gpt-4.1",             "strong",  0.00200, 0.00800, (7.3, 0.40)),
    ("anthropic", "claude-haiku-4-5",    "fast",    0.00100, 0.00500, (6.4, 0.35)),
    ("anthropic", "claude-sonnet-4-5",   "strong",  0.00300, 0.01500, (7.4, 0.40)),
    ("google",    "gemini-2.5-flash",    "fast",    0.00030, 0.00250, (6.2, 0.38)),
]

# The orchestration service ships its own price sheet; for these models it is
# out of date relative to the finance price list (ratio old/new).
LEGACY_PRICE_MULTIPLIER = {"gpt-4.1": 1.25, "claude-sonnet-4-5": 1.20, "gemini-2.5-flash": 1.50}

# Probability that one failed LLM call (as seen by the user) tips the
# conversation into a human hand-off
P_ESCALATE_PER_FAILURE = 0.20

# Which intents are "hard" and get routed to strong models more often
HARD_INTENTS = {"transaction_dispute", "account_verification", "loan_inquiry", "payment_failed"}

STATUS_BASE = {"success": 0.955, "error": 0.022, "timeout": 0.015, "rate_limited": 0.008}
ERROR_TYPES = {
    "error":        {"provider_5xx": 0.45, "content_filter": 0.20, "invalid_request": 0.20, "context_length": 0.15},
    "timeout":      {"upstream_timeout": 1.0},
    "rate_limited": {"rate_limit_429": 1.0},
}

ESCALATION_REASONS = {
    "policy_requires_human": 0.30,
    "low_confidence":        0.22,
    "user_requested_agent":  0.20,
    "unresolved_after_retry": 0.16,
    "fraud_suspected":       0.07,
    "llm_failure":           0.05,
}
# Intent-specific overrides of the escalation reason mix
ESCALATION_REASONS_BY_INTENT = {
    "transaction_dispute":  {"policy_requires_human": 0.55, "fraud_suspected": 0.20, "user_requested_agent": 0.15, "low_confidence": 0.05, "unresolved_after_retry": 0.03, "llm_failure": 0.02},
    "account_verification": {"policy_requires_human": 0.65, "user_requested_agent": 0.15, "low_confidence": 0.10, "unresolved_after_retry": 0.05, "fraud_suspected": 0.03, "llm_failure": 0.02},
    "card_block":           {"fraud_suspected": 0.35, "policy_requires_human": 0.30, "user_requested_agent": 0.20, "low_confidence": 0.08, "unresolved_after_retry": 0.05, "llm_failure": 0.02},
    "app_login_issue":      {"unresolved_after_retry": 0.45, "user_requested_agent": 0.25, "low_confidence": 0.15, "llm_failure": 0.08, "policy_requires_human": 0.05, "fraud_suspected": 0.02},
    "payment_failed":       {"unresolved_after_retry": 0.35, "user_requested_agent": 0.25, "low_confidence": 0.20, "policy_requires_human": 0.10, "llm_failure": 0.07, "fraud_suspected": 0.03},
    "general_question":     {"low_confidence": 0.50, "user_requested_agent": 0.25, "unresolved_after_retry": 0.12, "llm_failure": 0.08, "policy_requires_human": 0.03, "fraud_suspected": 0.02},
    "fee_question":         {"low_confidence": 0.35, "user_requested_agent": 0.30, "unresolved_after_retry": 0.20, "policy_requires_human": 0.08, "llm_failure": 0.05, "fraud_suspected": 0.02},
    "loan_inquiry":         {"policy_requires_human": 0.50, "user_requested_agent": 0.25, "low_confidence": 0.15, "unresolved_after_retry": 0.05, "llm_failure": 0.03, "fraud_suspected": 0.02},
}
TEAMS = {"tier1_support": 0.55, "disputes": 0.20, "kyc_compliance": 0.15, "fraud_ops": 0.10}

# Share of records that get each type of corruption
MESSY_RATES = {
    "duplicate_request_id":       0.003,
    "missing_conversation_id":    0.002,
    "negative_latency":           0.001,
    "token_sum_mismatch":         0.005,
    "unknown_model_name":         0.002,
    "resolved_and_escalated":     0.004,
    "late_arriving_request":      0.004,
    "stale_price_cost":           0.010,  # cost_usd computed from a lagging price sheet
    "null_satisfaction":          0.35,   # not an error: users simply don't rate
}


def pick(rng: np.random.Generator, table: dict, n: int) -> np.ndarray:
    keys = list(table.keys())
    p = np.array(list(table.values()), dtype=float)
    return rng.choice(keys, size=n, p=p / p.sum())


# --------------------------------------------------------------------------- #
# Generators
# --------------------------------------------------------------------------- #

def gen_users(rng, n_users: int, start: datetime, end: datetime) -> pd.DataFrame:
    # Signups: ~55% before the observation window, rest spread across it
    window_days = (end - start).days
    pre = int(n_users * 0.55)
    created = np.concatenate([
        start - pd.to_timedelta(rng.integers(1, 365, size=pre), unit="D"),
        start + pd.to_timedelta(rng.integers(0, window_days, size=n_users - pre), unit="D"),
    ])
    created = created + pd.to_timedelta(rng.integers(0, 86400, size=n_users), unit="s")
    return pd.DataFrame({
        "user_id": [f"u_{i:06d}" for i in range(1, n_users + 1)],
        "created_at": created,
        "country": pick(rng, COUNTRIES, n_users),
        "segment": pick(rng, SEGMENTS, n_users),
        "signup_channel": pick(rng, SIGNUP_CHANNELS, n_users),
    })


def gen_conversations(rng, users: pd.DataFrame, n_conv: int, start: datetime, end: datetime) -> pd.DataFrame:
    window_secs = int((end - start).total_seconds())
    # Users with more conversations: business/premium heavier; sample with weights
    w = users["segment"].map({"retail": 1.0, "premium": 1.6, "business": 2.4}).to_numpy()
    user_idx = rng.choice(len(users), size=n_conv, p=w / w.sum())
    user_created = users["created_at"].to_numpy()[user_idx]

    started = start + pd.to_timedelta(rng.integers(0, window_secs, size=n_conv), unit="s")
    # Conversations cannot precede signup: clamp forward
    started = np.maximum(started, user_created + np.timedelta64(60, "s"))
    # Weekly seasonality: fewer conversations on weekends -> drop 35% of weekend rows
    dow = pd.DatetimeIndex(started).dayofweek
    keep = ~((dow >= 5) & (rng.random(n_conv) < 0.35))
    started, user_idx = started[keep], user_idx[keep]
    n = len(started)

    duration = rng.lognormal(mean=5.3, sigma=0.7, size=n).astype(int)  # median ~200s
    intents = pick(rng, {k: v[0] for k, v in INTENTS.items()}, n)
    esc_p = np.array([INTENTS[i][1] for i in intents])
    escalated = rng.random(n) < esc_p
    resolved = ~escalated & (rng.random(n) < 0.93)  # some are neither: abandoned

    sat_mean = np.array([INTENTS[i][2] for i in intents]) - escalated * 0.9
    sat = np.clip(np.round(rng.normal(sat_mean, 0.9)), 1, 5)
    sat = np.where(rng.random(n) < MESSY_RATES["null_satisfaction"], np.nan, sat)

    df = pd.DataFrame({
        "conversation_id": [f"c_{i:07d}" for i in range(1, n + 1)],
        "user_id": users["user_id"].to_numpy()[user_idx],
        "started_at": started,
        "ended_at": started + pd.to_timedelta(duration, unit="s"),
        "channel": pick(rng, CHANNELS, n),
        "initial_intent": intents,
        "resolved_without_escalation": resolved,
        "escalated": escalated,
        "satisfaction_score": sat,
    })
    df = df.sort_values("started_at").reset_index(drop=True)
    df["conversation_id"] = [f"c_{i:07d}" for i in range(1, n + 1)]
    return df


def gen_prices(start: datetime, end: datetime) -> pd.DataFrame:
    dates = pd.date_range(start.date(), end.date(), freq="D")
    rows = []
    for provider, model, _tier, inp, out, _lat in MODELS:
        for d in dates:
            i, o = inp, out
            # A mid-window price cut on the strong OpenAI model (realistic; stresses cost reconciliation)
            if model == "gpt-4.1" and d >= dates[len(dates) // 2]:
                i, o = inp * 0.8, out * 0.8
            rows.append((d.date(), provider, model, i, o))
    return pd.DataFrame(rows, columns=[
        "price_date", "model_provider", "model_name",
        "input_price_per_1k_tokens", "output_price_per_1k_tokens",
    ])


def gen_requests(rng, conv: pd.DataFrame, prices: pd.DataFrame, target_requests: int) -> pd.DataFrame:
    n_conv = len(conv)
    # Requests per conversation: 1 + Poisson, scaled so the total is near target
    lam = max(target_requests / n_conv - 1, 0.5)
    per_conv = 1 + rng.poisson(lam, size=n_conv)
    per_conv = np.where(conv["escalated"].to_numpy(), per_conv + rng.integers(0, 2, size=n_conv), per_conv)
    total = int(per_conv.sum())

    conv_idx = np.repeat(np.arange(n_conv), per_conv)
    seq = np.concatenate([np.arange(k) for k in per_conv])

    # Route: fast model first; later turns and hard intents lean on strong models
    intents = conv["initial_intent"].to_numpy()[conv_idx]
    hard = np.isin(intents, list(HARD_INTENTS))
    p_strong = 0.12 + 0.25 * hard + 0.10 * (seq > 0)
    strong = rng.random(total) < p_strong
    fast_models = [m for m in MODELS if m[2] == "fast"]
    strong_models = [m for m in MODELS if m[2] == "strong"]
    fast_choice = rng.choice(len(fast_models), size=total, p=[0.55, 0.30, 0.15])
    strong_choice = rng.choice(len(strong_models), size=total, p=[0.6, 0.4])
    model_rows = [
        strong_models[strong_choice[i]] if strong[i] else fast_models[fast_choice[i]]
        for i in range(total)
    ]
    provider = np.array([m[0] for m in model_rows])
    model = np.array([m[1] for m in model_rows])
    lat_mu = np.array([m[5][0] for m in model_rows])
    lat_sigma = np.array([m[5][1] for m in model_rows])

    # Timestamps spread inside the conversation window
    started = conv["started_at"].to_numpy()[conv_idx]
    ended = conv["ended_at"].to_numpy()[conv_idx]
    span = (ended - started) / np.timedelta64(1, "s")
    frac = (seq + rng.random(total) * 0.8) / np.maximum(per_conv[conv_idx], 1)
    created = started + pd.to_timedelta(np.floor(span * frac), unit="s")

    prompt_tokens = np.clip(rng.lognormal(6.6, 0.45, size=total), 120, 8000).astype(int)  # median ~735
    prompt_tokens = prompt_tokens + seq * 180  # context grows with each turn
    completion_tokens = np.clip(rng.lognormal(5.2, 0.55, size=total), 20, 2000).astype(int)  # median ~180

    status = pick(rng, STATUS_BASE, total)
    # A reliability incident: one provider has a bad day (error + timeout spike)
    incident_day = pd.Timestamp(conv["started_at"].min().normalize()) + pd.Timedelta(days=41)
    on_incident = (pd.DatetimeIndex(created).normalize() == incident_day) & (provider == "openai")
    incident_status = pick(rng, {"success": 0.70, "error": 0.18, "timeout": 0.12}, total)
    status = np.where(on_incident, incident_status, status)

    error_type = np.full(total, None, dtype=object)
    for s, table in ERROR_TYPES.items():
        mask = status == s
        error_type[mask] = pick(rng, table, int(mask.sum()))
    # Failed requests still burn prompt tokens but produce no completion
    completion_tokens = np.where(status == "success", completion_tokens, 0)
    completion_tokens = np.where(status == "error", rng.integers(0, 40, size=total), completion_tokens)

    latency = np.exp(rng.normal(lat_mu, lat_sigma)).astype(int)
    latency = latency + (completion_tokens * rng.uniform(8, 14, size=total)).astype(int)  # output-bound
    latency = np.where(status == "timeout", rng.integers(30000, 60000, size=total), latency)
    latency = np.where(status == "rate_limited", rng.integers(50, 400, size=total), latency)

    total_tokens = prompt_tokens + completion_tokens

    # Cost from the price table valid on the request date
    req_date = pd.DatetimeIndex(created).date
    price_lookup = prices.set_index(["price_date", "model_name"])[
        ["input_price_per_1k_tokens", "output_price_per_1k_tokens"]
    ]
    key = pd.MultiIndex.from_arrays([req_date, model])
    p = price_lookup.reindex(key)
    cost = (prompt_tokens * p["input_price_per_1k_tokens"].to_numpy()
            + completion_tokens * p["output_price_per_1k_tokens"].to_numpy()) / 1000.0
    cost = np.round(cost, 6)

    df = pd.DataFrame({
        "request_id": [f"r_{i:08d}" for i in range(1, total + 1)],
        "conversation_id": conv["conversation_id"].to_numpy()[conv_idx],
        "created_at": created,
        "model_provider": provider,
        "model_name": model,
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "total_tokens": total_tokens,
        "latency_ms": latency,
        "cost_usd": cost,
        "status": status,
        "error_type": error_type,
    })
    df["_ingested_at"] = df["created_at"] + pd.to_timedelta(rng.integers(1, 90, size=total), unit="s")
    return df


def gen_intent_predictions(rng, conv: pd.DataFrame) -> pd.DataFrame:
    n = len(conv)
    intents = list(INTENTS.keys())
    true_intent = conv["initial_intent"].to_numpy()
    # Per-intent classifier accuracy; confusable pairs
    acc = {i: 0.90 for i in intents}
    acc.update({"payment_failed": 0.80, "transfer_status": 0.82, "fee_question": 0.84, "general_question": 0.70})
    confusions = {
        "payment_failed": "transfer_status", "transfer_status": "payment_failed",
        "fee_question": "limits_change", "general_question": "balance_inquiry",
        "card_delivery": "card_block", "loan_inquiry": "limits_change",
    }
    correct = rng.random(n) < np.array([acc[i] for i in true_intent])
    wrong_alt = np.array([confusions.get(i, rng.choice(intents)) for i in true_intent])
    predicted = np.where(correct, true_intent, wrong_alt)
    # Confidence: higher when correct, with overlap
    conf = np.where(correct, rng.beta(8, 2, size=n), rng.beta(3, 3, size=n))
    conf = np.round(np.clip(conf, 0.05, 0.999), 3)

    # ~30% of predictions get a human review label; only those have is_correct populated
    reviewed = rng.random(n) < 0.30
    human = np.where(reviewed, true_intent, None)
    is_correct = np.where(reviewed, correct, None)

    return pd.DataFrame({
        "prediction_id": [f"p_{i:07d}" for i in range(1, n + 1)],
        "conversation_id": conv["conversation_id"].to_numpy(),
        "created_at": conv["started_at"].to_numpy() + np.timedelta64(2, "s"),
        "predicted_intent": predicted,
        "confidence": conf,
        "human_corrected_intent": human,
        "is_correct": is_correct,
    })


def apply_failure_effects(rng, conv: pd.DataFrame, req: pd.DataFrame) -> pd.DataFrame:
    """Let LLM failures feed back into the conversation outcome.

    A failed call (error / timeout / rate-limit) the user actually saw makes the
    conversation more likely to end in a hand-off, and that hand-off is
    attributed to `llm_failure`. This is what makes a provider incident show up
    downstream as an escalation spike, not only as an error-rate spike.
    """
    failed = (req[req["status"] != "success"]
              .groupby("conversation_id").size().rename("n_failed"))
    n_failed = conv["conversation_id"].map(failed).fillna(0).to_numpy()

    # Each failed call adds ~P_ESCALATE_PER_FAILURE of escalation probability
    p_extra = 1 - (1 - P_ESCALATE_PER_FAILURE) ** n_failed
    newly_escalated = (~conv["escalated"].to_numpy()) & (rng.random(len(conv)) < p_extra)
    # Already-escalated conversations that also saw failures: most of those
    # hand-offs are really about the failure
    reattributed = conv["escalated"].to_numpy() & (n_failed > 0) & (rng.random(len(conv)) < 0.4)

    conv = conv.copy()
    conv.loc[newly_escalated, "escalated"] = True
    conv.loc[newly_escalated, "resolved_without_escalation"] = False
    conv["_escalation_reason_override"] = np.where(newly_escalated | reattributed, "llm_failure", None)

    # Users who hit a failure rate the conversation lower (when they rate at all)
    hit = n_failed > 0
    conv.loc[hit, "satisfaction_score"] = np.clip(
        conv.loc[hit, "satisfaction_score"] - rng.integers(0, 2, size=int(hit.sum())), 1, 5
    )
    return conv


def gen_escalations(rng, conv: pd.DataFrame) -> pd.DataFrame:
    esc = conv[conv["escalated"]].reset_index(drop=True)
    n = len(esc)
    reasons = np.array([
        pick(rng, ESCALATION_REASONS_BY_INTENT.get(i, ESCALATION_REASONS), 1)[0]
        for i in esc["initial_intent"]
    ])
    override = esc["_escalation_reason_override"].to_numpy()
    reasons = np.where(pd.notna(override), override, reasons)
    team_by_intent = {
        "transaction_dispute": "disputes", "account_verification": "kyc_compliance",
    }
    team = np.array([
        team_by_intent.get(i, "fraud_ops" if r == "fraud_suspected" else pick(rng, TEAMS, 1)[0])
        for i, r in zip(esc["initial_intent"], reasons)
    ])
    handoff = np.clip(rng.lognormal(4.8, 0.6, size=n), 15, 3600).astype(int)  # median ~120s
    return pd.DataFrame({
        "escalation_id": [f"e_{i:06d}" for i in range(1, n + 1)],
        "conversation_id": esc["conversation_id"].to_numpy(),
        "created_at": esc["ended_at"].to_numpy() - pd.to_timedelta(handoff // 2, unit="s"),
        "reason": reasons,
        "handled_by_team": team,
        "time_to_handoff_seconds": handoff,
    })


# --------------------------------------------------------------------------- #
# Intentional corruption
# --------------------------------------------------------------------------- #

def corrupt(rng, conv: pd.DataFrame, req: pd.DataFrame, prices: pd.DataFrame):
    """Apply MESSY_RATES corruptions in place; return a manifest of what was broken."""
    manifest = []

    def sample(df, rate, exclude=()):
        pool = df.index.difference(pd.Index(exclude))
        k = max(1, int(len(df) * rate))
        return rng.choice(pool, size=k, replace=False)

    touched: set = set()

    # 1. Duplicate request IDs (exact replays of an existing row, ingested later)
    idx = sample(req, MESSY_RATES["duplicate_request_id"])
    dupes = req.loc[idx].copy()
    dupes["_ingested_at"] = dupes["_ingested_at"] + pd.Timedelta(minutes=5)
    manifest += [("raw_llm_requests", "request_id", r, "duplicate_request_id") for r in dupes["request_id"]]
    touched.update(idx)

    # 2. Missing conversation_id
    idx = sample(req, MESSY_RATES["missing_conversation_id"], touched)
    req.loc[idx, "conversation_id"] = None
    manifest += [("raw_llm_requests", "request_id", r, "missing_conversation_id") for r in req.loc[idx, "request_id"]]
    touched.update(idx)

    # 3. Negative latency (client clock skew)
    idx = sample(req, MESSY_RATES["negative_latency"], touched)
    req.loc[idx, "latency_ms"] = -req.loc[idx, "latency_ms"]
    manifest += [("raw_llm_requests", "request_id", r, "negative_latency") for r in req.loc[idx, "request_id"]]
    touched.update(idx)

    # 4. total_tokens != prompt + completion (double-counted system prompt)
    idx = sample(req, MESSY_RATES["token_sum_mismatch"], touched)
    req.loc[idx, "total_tokens"] = req.loc[idx, "total_tokens"] + rng.integers(50, 400, size=len(idx))
    manifest += [("raw_llm_requests", "request_id", r, "token_sum_mismatch") for r in req.loc[idx, "request_id"]]
    touched.update(idx)

    # 5. Model name not in the price table (a preview alias that leaked into prod logs)
    idx = sample(req, MESSY_RATES["unknown_model_name"], touched)
    req.loc[idx, "model_name"] = req.loc[idx, "model_name"] + "-preview"
    manifest += [("raw_llm_requests", "request_id", r, "unknown_model_name") for r in req.loc[idx, "request_id"]]
    touched.update(idx)

    # 6. Late-arriving requests: ingested days after the event
    idx = sample(req, MESSY_RATES["late_arriving_request"], touched)
    req.loc[idx, "_ingested_at"] = req.loc[idx, "created_at"] + pd.to_timedelta(rng.integers(2, 6, size=len(idx)), unit="D")
    manifest += [("raw_llm_requests", "request_id", r, "late_arriving_request") for r in req.loc[idx, "request_id"]]
    touched.update(idx)

    # 7. cost_usd logged with the orchestration service's embedded price sheet,
    #    which lags the finance price list for some models -> reconciliation drift
    idx = sample(req, MESSY_RATES["stale_price_cost"], touched)
    sub = req.loc[idx]
    factor = sub["model_name"].map(LEGACY_PRICE_MULTIPLIER).fillna(1.0).to_numpy()
    req.loc[idx, "cost_usd"] = np.round(sub["cost_usd"].to_numpy() * factor, 6)
    affected = sub["request_id"][factor != 1.0]
    manifest += [("raw_llm_requests", "request_id", r, "stale_price_cost") for r in affected]

    # 8. Conversations flagged both resolved-without-escalation AND escalated
    cidx = rng.choice(conv.index[conv["escalated"]], size=max(1, int(len(conv) * MESSY_RATES["resolved_and_escalated"])), replace=False)
    conv.loc[cidx, "resolved_without_escalation"] = True
    manifest += [("raw_conversations", "conversation_id", c, "resolved_and_escalated") for c in conv.loc[cidx, "conversation_id"]]

    req = pd.concat([req, dupes], ignore_index=True)
    return conv, req, pd.DataFrame(manifest, columns=["table_name", "key_column", "key_value", "issue"])


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--days", type=int, default=90)
    ap.add_argument("--users", type=int, default=6000)
    ap.add_argument("--conversations", type=int, default=38000)
    ap.add_argument("--requests", type=int, default=95000)
    ap.add_argument("--end-date", default="2026-08-31")
    args = ap.parse_args()

    rng = np.random.default_rng(args.seed)
    end = datetime.fromisoformat(args.end_date) + timedelta(days=1)
    start = end - timedelta(days=args.days)
    RAW_DIR.mkdir(parents=True, exist_ok=True)

    users = gen_users(rng, args.users, start, end)
    conv = gen_conversations(rng, users, args.conversations, start, end)
    prices = gen_prices(start, end)
    req = gen_requests(rng, conv, prices, args.requests)
    conv = apply_failure_effects(rng, conv, req)
    preds = gen_intent_predictions(rng, conv)
    esc = gen_escalations(rng, conv)
    conv = conv.drop(columns=["_escalation_reason_override"])
    conv, req, manifest = corrupt(rng, conv, req, prices)

    # Shuffle request order so raw data isn't suspiciously sorted
    req = req.sample(frac=1.0, random_state=args.seed).reset_index(drop=True)

    tables = {
        "raw_users": users,
        "raw_conversations": conv,
        "raw_llm_requests": req,
        "raw_intent_predictions": preds,
        "raw_escalations": esc,
        "raw_daily_model_prices": prices,
        "_messy_manifest": manifest,
    }
    for name, df in tables.items():
        path = RAW_DIR / f"{name}.csv"
        df.to_csv(path, index=False)
        print(f"{name:26s} {len(df):>8,d} rows -> {path.relative_to(RAW_DIR.parents[1])}")

    print(f"\nwindow: {start.date()} .. {(end - timedelta(days=1)).date()} ({args.days} days), seed={args.seed}")
    print("messy records by issue:")
    print(manifest["issue"].value_counts().to_string())


if __name__ == "__main__":
    main()
