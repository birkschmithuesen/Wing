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
STATES = ["idle", "listening", "transcribing", "thinking", "speaking", "waiting", "attention", "error"]
SIZES = {"portrait": (411, 960), "landscape": (960, 411)}


def shots():
    for orient in SIZES:
        for theme in ("day", "night"):
            for state in STATES:
                params = dict(state=state, orient=orient, theme=theme, activity="Terminal")
                if state == "waiting":
                    params["conn"] = "offline"
                yield f"{state}-{orient}-{theme}", params
    # Variants: entry hint, connection states, status line contents, listening while Hermes works.
    for theme in ("day", "night"):
        yield f"idle-portrait-{theme}-entry", dict(state="idle", orient="portrait", theme=theme, hint="1")
        yield f"idle-portrait-{theme}-reconnecting", dict(state="idle", orient="portrait", theme=theme, conn="reconnecting")
        yield f"idle-portrait-{theme}-offline", dict(state="idle", orient="portrait", theme=theme, conn="offline")
    yield "idle-landscape-day-entry", dict(state="idle", orient="landscape", theme="day", hint="1")
    yield "idle-landscape-night-offline", dict(state="idle", orient="landscape", theme="night", conn="offline")
    yield "listening-portrait-night-offline", dict(state="listening", orient="portrait", theme="night", conn="offline")
    yield "listening-portrait-day-steer", dict(state="listening", orient="portrait", theme="day", working="1", activity="Terminal")
    yield "thinking-portrait-day-working", dict(state="thinking", orient="portrait", theme="day", activity="Working")
    yield "thinking-portrait-night-websearch", dict(state="thinking", orient="portrait", theme="night", activity="Web search")


def main():
    count = 0
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path="/usr/bin/chromium", args=["--no-sandbox"])
        for name, params in shots():
            w, h = SIZES[params["orient"]]
            page = browser.new_page(viewport={"width": w, "height": h}, device_scale_factor=1)
            query = "&".join(f"{k}={v}" for k, v in params.items()).replace(" ", "%20")
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
