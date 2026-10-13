"""Render PNG screenshots of the car-mode mockup (docs only, not product code).

Usage (from the repo root):
    python3 docs/superpowers/specs/2026-10-14-wing-car-mode-shots/render_shots.py

Needs the Python package `playwright` and a Chromium at /usr/bin/chromium.
Writes <state>-<orient>-<theme>[-<variant>].png next to this script.
"""
import pathlib
import sys

from playwright.sync_api import sync_playwright

HERE = pathlib.Path(__file__).resolve().parent
MOCKUP = HERE.parent / "2026-10-14-wing-car-mode-mockup.html"
STATES = ["idle", "listening", "transcribing", "thinking", "speaking", "attention", "error", "offline"]
SIZES = {"portrait": (411, 960), "landscape": (960, 411)}


def shots():
    for orient in SIZES:
        for theme in ("day", "night"):
            for state in STATES:
                yield f"{state}-{orient}-{theme}", dict(state=state, orient=orient, theme=theme)
    # Variants for the open decisions (D1 hint, D2 exit label, D3 circle look).
    for theme in ("day", "night"):
        for state in ("idle", "listening", "speaking"):
            yield f"{state}-portrait-{theme}-lookB", dict(state=state, orient="portrait", theme=theme, look="B")
        yield f"idle-landscape-{theme}-lookB", dict(state="idle", orient="landscape", theme=theme, look="B")
    yield "thinking-portrait-day-d1B", dict(state="thinking", orient="portrait", theme="day", d1="B")
    yield "thinking-portrait-day-d1C", dict(state="thinking", orient="portrait", theme="day", d1="C")
    yield "idle-portrait-day-d2B", dict(state="idle", orient="portrait", theme="day", d2="B")
    yield "idle-portrait-day-d2C", dict(state="idle", orient="portrait", theme="day", d2="C")
    yield "offline-portrait-night-reconnecting", dict(state="offline", orient="portrait", theme="night", reconnecting="1")
    yield "thinking-portrait-night-steered", dict(state="thinking", orient="portrait", theme="night", temp="Added to the running reply")


def main():
    count = 0
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path="/usr/bin/chromium", args=["--no-sandbox"])
        for name, params in shots():
            w, h = SIZES[params["orient"]]
            page = browser.new_page(viewport={"width": w, "height": h}, device_scale_factor=1)
            query = "&".join(f"{k}={v}" for k, v in params.items())
            page.goto(f"{MOCKUP.as_uri()}?shot=1&{query}")
            page.wait_for_timeout(150)
            page.screenshot(path=str(HERE / f"{name}.png"))
            page.close()
            count += 1
        browser.close()
    print(f"rendered {count} screenshots to {HERE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
