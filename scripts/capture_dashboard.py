"""Capture one screenshot per dashboard tab for the README.

Requires a running dashboard (streamlit run dashboards/app.py) and
`pip install playwright && playwright install chromium`.

Usage:
    python scripts/capture_dashboard.py [--url http://localhost:8501]
"""

from __future__ import annotations

import argparse
from pathlib import Path

from playwright.sync_api import sync_playwright

OUT = Path(__file__).resolve().parents[1] / "docs" / "img"
TABS = ["Product health", "LLM cost", "Reliability", "Quality", "Data quality"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://localhost:8501")
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)

    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": 1440, "height": 1000}, device_scale_factor=1)
        page.goto(args.url)
        page.wait_for_selector("[data-testid='stTab']", timeout=60_000)
        page.wait_for_timeout(4000)
        for name in TABS:
            page.get_by_role("tab", name=name, exact=True).click()
            page.wait_for_timeout(2500)
            slug = name.lower().replace(" ", "_")
            page.screenshot(path=str(OUT / f"dashboard_{slug}.png"), full_page=True)
            print("saved", OUT / f"dashboard_{slug}.png")
            if name == "Reliability":
                # the anomaly section sits below the fold; scroll it into view
                page.get_by_role("heading", name="Anomaly flags").scroll_into_view_if_needed()
                page.wait_for_timeout(1500)
                page.screenshot(path=str(OUT / "dashboard_anomalies.png"))
                print("saved", OUT / "dashboard_anomalies.png")
        browser.close()


if __name__ == "__main__":
    main()
