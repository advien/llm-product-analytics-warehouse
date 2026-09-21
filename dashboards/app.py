"""LLM Product Analytics dashboard.

Reads ONLY mart tables from the DuckDB warehouse built by dbt. No raw or
staging tables are touched here - if a number looks wrong, the fix belongs in
the models, not in the dashboard.

Run:  streamlit run dashboards/app.py
"""

from __future__ import annotations

from pathlib import Path

import duckdb
import pandas as pd
import plotly.graph_objects as go
import streamlit as st

DB_PATH = Path(__file__).resolve().parents[1] / "data" / "processed" / "warehouse.duckdb"

# Categorical palette (fixed slot order, assigned to entities - never cycled)
SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#4a3aa7", "#e34948"]
MODEL_ORDER = ["gpt-4o-mini", "gpt-4.1", "claude-haiku-4-5", "claude-sonnet-4-5", "gemini-2.5-flash"]
MODEL_COLOR = dict(zip(MODEL_ORDER, SERIES))
PROVIDER_ORDER = ["openai", "anthropic", "google"]
PROVIDER_COLOR = dict(zip(PROVIDER_ORDER, SERIES))
STATUS_ORDER = ["error", "timeout", "rate_limited"]
STATUS_COLOR = dict(zip(STATUS_ORDER, [SERIES[7], SERIES[3], SERIES[6]]))
SEQ_BLUE = ["#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95", "#0d366b"]
INK, INK2, GRID = "#0b0b0b", "#52514e", "#e6e5e1"

st.set_page_config(page_title="LLM Product Analytics", layout="wide")


@st.cache_resource
def connect():
    return duckdb.connect(str(DB_PATH), read_only=True)


@st.cache_data(ttl=600)
def query(sql: str) -> pd.DataFrame:
    return connect().execute(sql).df()


def base_layout(fig: go.Figure, height: int = 300, title: str = "", **kw) -> go.Figure:
    layout = dict(
        height=height,
        margin=dict(l=8, r=8, t=36, b=8),
        paper_bgcolor="rgba(0,0,0,0)",
        plot_bgcolor="rgba(0,0,0,0)",
        font=dict(color=INK2, size=12),
        title=dict(text=title, font=dict(color=INK, size=14), x=0),
        legend=dict(orientation="h", y=-0.18, x=0, font=dict(size=11)),
        hovermode="x unified",
    )
    layout.update(kw)  # caller overrides win
    fig.update_layout(**layout)
    fig.update_xaxes(showgrid=False, zeroline=False, linecolor=GRID)
    fig.update_yaxes(gridcolor=GRID, zeroline=False, showline=False)
    return fig


def line(df, x, ys: dict, title, yfmt=None, height=300):
    fig = go.Figure()
    for i, (col, label) in enumerate(ys.items()):
        fig.add_trace(go.Scatter(x=df[x], y=df[col], name=label, mode="lines",
                                 line=dict(width=2, color=SERIES[i])))
    base_layout(fig, height, title=title, showlegend=len(ys) > 1)
    if yfmt:
        fig.update_yaxes(tickformat=yfmt)
    return fig


def stacked_bars(df, x, group, y, order, colors, title, yfmt=None, height=300):
    fig = go.Figure()
    for g in order:
        sub = df[df[group] == g]
        if sub.empty:
            continue
        fig.add_trace(go.Bar(x=sub[x], y=sub[y], name=g, marker_color=colors[g],
                             marker_line=dict(width=1, color="white")))
    base_layout(fig, height, title=title, barmode="stack", bargap=0.25)
    if yfmt:
        fig.update_yaxes(tickformat=yfmt)
    return fig


def hbar(df, y, x, title, color=SERIES[0], xfmt=None, height=320):
    fig = go.Figure(go.Bar(x=df[x], y=df[y], orientation="h", marker_color=color,
                           texttemplate="%{x:" + (xfmt or ".2f") + "}", textposition="outside",
                           textfont=dict(color=INK2, size=11)))
    base_layout(fig, height, title=title, hovermode="y", showlegend=False)
    fig.update_yaxes(showgrid=False, autorange="reversed")
    fig.update_xaxes(showgrid=True, gridcolor=GRID, tickformat=xfmt)
    return fig


def fmt_pct(v):
    return "-" if pd.isna(v) else f"{v:.1%}"


# ----------------------------------------------------------------------------- #
# Filters
# ----------------------------------------------------------------------------- #
daily_all = query("select * from marts.fct_daily_product_metrics where not is_partial_day order by metric_date")
d_min, d_max = daily_all.metric_date.min(), daily_all.metric_date.max()

st.title("LLM Product Analytics")
st.caption("Assistant product warehouse - all panels read dbt mart tables only.")

fc1, fc2, _ = st.columns([2, 2, 4])
with fc1:
    start, end = st.date_input("Date range", (d_min, d_max), min_value=d_min, max_value=d_max)
with fc2:
    models = st.multiselect("Models", MODEL_ORDER, default=MODEL_ORDER)

date_clause = f"between '{start}' and '{end}'"
model_list = ", ".join(f"'{m}'" for m in models) or "''"

daily = daily_all[(daily_all.metric_date >= pd.Timestamp(start)) & (daily_all.metric_date <= pd.Timestamp(end))]
model_costs = query(f"""
    select * from marts.fct_daily_model_costs
    where request_date {date_clause} and model_name in ({model_list})
    order by request_date
""")
reliability = query(f"""
    select * from marts.mart_model_reliability_daily
    where request_date {date_clause} and model_name in ({model_list})
    order by request_date
""")
intents = query("select * from marts.mart_intent_quality order by n_conversations desc")
conv = query(f"""
    select initial_intent, escalation_reason, intent_confidence_bucket, is_escalated,
           intent_is_human_reviewed, intent_is_correct, count(*) as n
    from marts.fct_conversations
    where conversation_date {date_clause}
    group by all
""")

# ----------------------------------------------------------------------------- #
# Headline tiles
# ----------------------------------------------------------------------------- #
tot = daily.sum(numeric_only=True)
tiles = st.columns(6)
tiles[0].metric("Conversations", f"{int(tot.n_conversations):,}")
tiles[1].metric("Auto-resolution", fmt_pct(tot.n_auto_resolved / tot.n_conversations))
tiles[2].metric("Escalation rate", fmt_pct(tot.n_escalated / tot.n_conversations))
csat = (daily.avg_satisfaction_score * daily.n_rated).sum() / tot.n_rated
tiles[3].metric("Avg CSAT", f"{csat:.2f} / 5")
tiles[4].metric("LLM cost", f"${tot.total_cost_usd:,.2f}",
                help="Recomputed from tokens x price list, not the logged value")
tiles[5].metric("Error rate", fmt_pct(tot.n_failed_requests / tot.n_requests))

tab_health, tab_cost, tab_rel, tab_quality, tab_dq = st.tabs(
    ["Product health", "LLM cost", "Reliability", "Quality", "Data quality"]
)

# ----------------------------------------------------------------------------- #
with tab_health:
    c1, c2 = st.columns(2)
    c1.plotly_chart(line(daily, "metric_date", {"n_conversations": "Conversations", "n_active_users": "Active users"},
                         "Daily conversations and active users"), use_container_width=True)
    c2.plotly_chart(line(daily, "metric_date", {"auto_resolution_rate": "Auto-resolution", "escalation_rate": "Escalation",
                                                "abandonment_rate": "Abandoned"},
                         "Resolution mix", yfmt=".0%"), use_container_width=True)
    c3, c4 = st.columns(2)
    c3.plotly_chart(line(daily, "metric_date", {"avg_satisfaction_score": "Avg satisfaction (1-5)"},
                         "Satisfaction score"), use_container_width=True)
    c4.plotly_chart(line(daily, "metric_date", {"avg_requests_per_conversation": "Requests / conversation"},
                         "LLM requests per conversation"), use_container_width=True)

    st.subheader("By intent")
    st.dataframe(
        intents[["intent", "intent_category", "risk_level", "n_conversations", "auto_resolution_rate",
                 "escalation_rate", "avg_satisfaction_score", "top_escalation_reason", "cost_per_conversation_usd"]]
        .style.format({"auto_resolution_rate": "{:.1%}", "escalation_rate": "{:.1%}",
                       "avg_satisfaction_score": "{:.2f}", "cost_per_conversation_usd": "${:.4f}"}),
        use_container_width=True, hide_index=True,
    )

# ----------------------------------------------------------------------------- #
with tab_cost:
    c1, c2 = st.columns(2)
    c1.plotly_chart(stacked_bars(model_costs, "request_date", "model_name", "total_cost_usd", MODEL_ORDER, MODEL_COLOR,
                                 "Daily LLM cost by model (USD)", yfmt="$.2f"), use_container_width=True)
    c2.plotly_chart(line(daily, "metric_date", {"cost_per_conversation_usd": "Cost / conversation",
                                                "cost_per_auto_resolved_conversation_usd": "Cost / auto-resolved"},
                         "Unit cost (USD)", yfmt="$.4f"), use_container_width=True)
    c3, c4 = st.columns(2)
    by_model = (model_costs.groupby("model_name", as_index=False)
                .agg(cost=("total_cost_usd", "sum"), requests=("n_requests", "sum"), tokens=("total_tokens", "sum")))
    by_model["cost_per_1k_tokens"] = by_model.cost / by_model.tokens * 1000
    by_model = by_model.set_index("model_name").reindex([m for m in MODEL_ORDER if m in models]).reset_index()
    c3.plotly_chart(hbar(by_model, "model_name", "cost", "Total cost by model (USD)", xfmt="$.2f"), use_container_width=True)
    c4.plotly_chart(stacked_bars(model_costs, "request_date", "model_name", "total_tokens", MODEL_ORDER, MODEL_COLOR,
                                 "Daily token usage by model", yfmt="~s"), use_container_width=True)
    st.plotly_chart(hbar(by_model, "model_name", "cost_per_1k_tokens", "Effective cost per 1k tokens (USD)",
                         xfmt="$.4f", height=260), use_container_width=True)

# ----------------------------------------------------------------------------- #
with tab_rel:
    c1, c2 = st.columns(2)
    c1.plotly_chart(line(daily, "metric_date", {"error_rate": "Error rate (all failures)", "timeout_rate": "Timeout rate"},
                         "Request failure rate", yfmt=".1%"), use_container_width=True)
    c2.plotly_chart(line(daily, "metric_date", {"p50_latency_ms": "p50", "p95_latency_ms": "p95"},
                         "Latency percentiles (ms)"), use_container_width=True)

    c3, c4 = st.columns(2)
    fig = go.Figure()
    for m in [m for m in MODEL_ORDER if m in models]:
        sub = reliability[reliability.model_name == m]
        fig.add_trace(go.Scatter(x=sub.request_date, y=sub.p95_latency_ms, name=m, mode="lines",
                                 line=dict(width=2, color=MODEL_COLOR[m])))
    c3.plotly_chart(base_layout(fig, title="p95 latency by model (ms)"), use_container_width=True)

    failures = (reliability.melt(id_vars=["request_date"],
                                 value_vars=["n_error_requests", "n_timeout_requests", "n_rate_limited_requests"],
                                 var_name="status", value_name="n")
                .assign(status=lambda d: d.status.str.replace("n_", "").str.replace("_requests", ""))
                .groupby(["request_date", "status"], as_index=False).n.sum())
    c4.plotly_chart(stacked_bars(failures, "request_date", "status", "n", STATUS_ORDER, STATUS_COLOR,
                                 "Failed requests by status"), use_container_width=True)

    st.subheader("Model scorecard")
    score = (reliability.groupby(["model_provider", "model_name", "model_tier"], as_index=False)
             .agg(requests=("n_requests", "sum"), failed=("n_failed_requests", "sum"),
                  p95_ms=("p95_latency_ms", "median"), provider_5xx=("n_provider_5xx", "sum"),
                  cost=("total_cost_usd", "sum")))
    score["error_rate"] = score.failed / score.requests
    score["cost_per_request"] = score.cost / score.requests
    st.dataframe(score.style.format({"error_rate": "{:.2%}", "p95_ms": "{:,.0f}", "cost": "${:,.2f}",
                                     "cost_per_request": "${:.4f}"}),
                 use_container_width=True, hide_index=True)

# ----------------------------------------------------------------------------- #
with tab_quality:
    c1, c2 = st.columns(2)
    c1.plotly_chart(line(daily, "metric_date", {"intent_accuracy": "Accuracy (reviewed subset)",
                                                "corrected_intent_rate": "Corrected by human"},
                         "Intent classifier quality", yfmt=".0%"), use_container_width=True)
    acc = intents.sort_values("intent_accuracy")
    c2.plotly_chart(hbar(acc, "intent", "intent_accuracy", "Intent accuracy by intent", xfmt=".0%", height=360),
                    use_container_width=True)

    c3, c4 = st.columns(2)
    conf_order = ["<0.50", "0.50-0.69", "0.70-0.79", "0.80-0.89", "0.90-1.00"]
    conf = (conv.groupby("intent_confidence_bucket").n.sum().reindex(conf_order).fillna(0).reset_index())
    fig = go.Figure(go.Bar(x=conf.intent_confidence_bucket, y=conf.n,
                           marker_color=SEQ_BLUE[2:], marker_line=dict(width=1, color="white")))
    c3.plotly_chart(base_layout(fig, title="Confidence distribution", hovermode="x", showlegend=False),
                    use_container_width=True)

    esc = (conv[conv.is_escalated].groupby(["initial_intent", "escalation_reason"], as_index=False).n.sum())
    top_intents = esc.groupby("initial_intent").n.sum().sort_values(ascending=False).index[:8]
    esc = esc[esc.initial_intent.isin(top_intents)]
    reason_order = ["policy_requires_human", "unresolved_after_retry", "user_requested_agent",
                    "low_confidence", "fraud_suspected", "llm_failure"]
    fig = go.Figure()
    for i, r in enumerate(reason_order):
        sub = esc[esc.escalation_reason == r].set_index("initial_intent").reindex(top_intents).fillna(0)
        fig.add_trace(go.Bar(x=sub.index, y=sub.n, name=r, marker_color=SERIES[i],
                             marker_line=dict(width=1, color="white")))
    c4.plotly_chart(base_layout(fig, height=360, title="Escalations by intent and reason", barmode="stack",
                                hovermode="x"), use_container_width=True)

# ----------------------------------------------------------------------------- #
with tab_dq:
    st.markdown(
        "Raw feeds are intentionally messy; staging flags (never drops) each defect. "
        "This panel shows how much of the data carried a flag and how the cost ledger reconciles."
    )
    dq = query(f"""
        select
            count(*)                                            as requests,
            count(*) filter (where is_orphan)                   as orphan_no_conversation,
            count(*) filter (where has_invalid_latency)         as negative_latency,
            count(*) filter (where has_token_sum_mismatch)      as token_sum_mismatch,
            count(*) filter (where has_model_alias)             as model_alias_mapped,
            count(*) filter (where had_duplicate_ingest)        as duplicate_ingest_deduped,
            count(*) filter (where is_late_arriving)            as late_arriving,
            count(*) filter (where not is_cost_reconciled)      as cost_not_reconciled,
            sum(cost_usd)                                       as calculated_cost,
            sum(logged_cost_usd)                                as logged_cost
        from marts.fct_llm_requests
        where request_date {date_clause}
    """).iloc[0]
    k = st.columns(4)
    k[0].metric("Requests in range", f"{int(dq.requests):,}")
    k[1].metric("Cost (recomputed)", f"${dq.calculated_cost:,.2f}")
    k[2].metric("Cost (as logged)", f"${dq.logged_cost:,.2f}", delta=f"{dq.logged_cost - dq.calculated_cost:+.2f} vs recomputed",
                delta_color="inverse")
    k[3].metric("Cost mismatches", f"{int(dq.cost_not_reconciled):,}", help="Outside 0.5% / $0.00001 tolerance")

    flags = pd.DataFrame({
        "flag": ["orphan_no_conversation", "negative_latency", "token_sum_mismatch", "model_alias_mapped",
                 "duplicate_ingest_deduped", "late_arriving", "cost_not_reconciled"],
    })
    flags["rows"] = flags.flag.map(dq).astype(int)
    flags["share"] = flags.rows / dq.requests
    c1, c2 = st.columns(2)
    c1.plotly_chart(hbar(flags, "flag", "rows", "Flagged requests by defect type", xfmt=",d", height=320),
                    use_container_width=True)
    mm = model_costs.groupby("model_name", as_index=False).agg(mismatches=("n_cost_mismatches", "sum"),
                                                                delta=("cost_reconciliation_delta_usd", "sum"))
    mm = mm.set_index("model_name").reindex([m for m in MODEL_ORDER if m in models]).reset_index().fillna(0)
    mm["delta"] = -mm.delta  # positive = logged more than recomputed
    c2.plotly_chart(hbar(mm, "model_name", "delta", "Logged minus recomputed cost by model (USD)", xfmt="$.3f",
                         color=SERIES[1], height=320), use_container_width=True)
    conflicts = query(f"""
        select count(*) filter (where has_conflicting_resolution) as conflicting, count(*) as conversations
        from marts.fct_conversations where conversation_date {date_clause}
    """).iloc[0]
    st.caption(f"Conversations with contradictory raw resolution flags: {int(conflicts.conflicting):,} "
               f"of {int(conflicts.conversations):,} (resolved to `escalated` in staging).")
