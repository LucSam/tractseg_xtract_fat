"""Check actual Plotly geometry in a running Chrome browser (optional UI test).

Requires websocket-client. Start Chrome with --remote-debugging-port=9238 and
--remote-allow-origins=http://127.0.0.1:9238, then run:
python3 tests/viewer_geometry_check.py --url http://127.0.0.1:8766
"""

import argparse
import json
import math
import time
from typing import Any
from urllib.request import urlopen

import websocket


class Browser:
    def __init__(self, endpoint: str):
        with urlopen(endpoint + "/json", timeout=10) as response:
            tabs = json.load(response)
        tab = next(tab for tab in tabs if tab["type"] == "page")
        self.connection = websocket.create_connection(tab["webSocketDebuggerUrl"], origin=endpoint, timeout=60)
        self.request_id = 0

    def call(self, method: str, params: dict | None = None) -> dict:
        self.request_id += 1
        self.connection.send(json.dumps(dict(id=self.request_id, method=method, params=params or {})))
        while True:
            result = json.loads(self.connection.recv())
            if result.get("id") == self.request_id:
                if "error" in result:
                    raise RuntimeError(result["error"])
                return result.get("result", {})

    def evaluate(self, expression: str) -> Any:
        result = self.call("Runtime.evaluate", dict(expression=expression, returnByValue=True))
        if "exceptionDetails" in result:
            raise RuntimeError(result["exceptionDetails"])
        return result.get("result", {}).get("value")

    def wait_for(self, expression: str) -> None:
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if self.evaluate(expression):
                return
            time.sleep(0.1)
        raise TimeoutError(expression)

    def state(self) -> dict:
        return self.evaluate("""(() => {
          const s = document.getElementById('viewer')._fullLayout.scene;
          return {aspect: [s.aspectratio.x, s.aspectratio.y, s.aspectratio.z],
                  camera: s.camera, ranges: [s.xaxis.range, s.yaxis.range, s.zaxis.range]};
        })()""")


def same_values(before: Any, after: Any) -> bool:
    if isinstance(before, dict):
        return before.keys() == after.keys() and all(same_values(v, after[k]) for k, v in before.items())
    if isinstance(before, list):
        return len(before) == len(after) and all(same_values(a, b) for a, b in zip(before, after))
    if isinstance(before, (int, float)):
        return math.isclose(before, after, rel_tol=0, abs_tol=1e-12)
    return before == after


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8766")
    parser.add_argument("--debug-url", default="http://127.0.0.1:9238")
    args = parser.parse_args()
    browser = Browser(args.debug_url)
    try:
        browser.call("Page.enable")
        browser.call("Network.enable")
        browser.call("Network.setCacheDisabled", dict(cacheDisabled=True))
        separator = "&" if "?" in args.url else "?"
        browser.call("Page.navigate", dict(url=f"{args.url}{separator}geometry-check={time.time()}"))
        browser.wait_for("document.getElementById('viewer')?.dataset.algorithm === 'iFOD2'")
        algorithms = browser.evaluate("Array.from(document.getElementById('algorithm').options, o => o.value)")
        reference = browser.state()
        for algorithm in algorithms:
            browser.evaluate(f"document.getElementById('algorithm').value={json.dumps(algorithm)};"
                             "document.getElementById('algorithm').dispatchEvent(new Event('change'));true")
            browser.wait_for(f"document.getElementById('viewer').dataset.algorithm === {json.dumps(algorithm)}"
                             " && !document.getElementById('algorithm').disabled")
            for side in ("both", "left", "right"):
                browser.evaluate(f"document.getElementById('side').value={json.dumps(side)};"
                                 "document.getElementById('side').dispatchEvent(new Event('change'));true")
                for visible in (False, True):
                    browser.evaluate("document.getElementById('brain').click();true")
                    browser.wait_for("document.getElementById('viewer').data[0].visible === "
                                     + json.dumps(visible))
                    state = browser.state()
                    if not same_values(reference, state):
                        raise AssertionError(f"Geometry changed for {algorithm}/{side}/brain={visible}: "
                                             f"{reference} -> {state}")
                    scales = [size / (bounds[1] - bounds[0])
                              for size, bounds in zip(state["aspect"], state["ranges"])]
                    if not all(math.isclose(v, scales[0], abs_tol=1e-12) for v in scales):
                        raise AssertionError(f"Unequal physical scale: {scales}")
            print(f"{algorithm}: all sides and brain off/on preserve camera, scale and proportions.", flush=True)
    finally:
        browser.connection.close()


if __name__ == "__main__":
    main()
