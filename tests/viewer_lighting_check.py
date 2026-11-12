"""Check fixed skylight reflections and optionally capture the README preview.

Use the Chrome setup documented in viewer_geometry_check.py. Requires Pillow
and NumPy as well as websocket-client. To also refresh the repository image:
python3 tests/viewer_lighting_check.py --preview assets/fat_3d.png
"""

import argparse
import base64
from io import BytesIO
from pathlib import Path
import time

import numpy as np
from PIL import Image

from viewer_geometry_check import Browser


def evaluate(browser: Browser, expression: str) -> None:
    result = browser.call("Runtime.evaluate", dict(expression=expression, awaitPromise=True))
    if "exceptionDetails" in result:
        raise RuntimeError(result["exceptionDetails"])


def capture(browser: Browser, size: int) -> bytes:
    evaluate(browser, "new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))")
    time.sleep(0.5)
    return base64.b64decode(browser.call("Page.captureScreenshot", dict(
        format="png", clip=dict(x=0, y=0, width=size, height=size, scale=1)))['data'])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8766")
    parser.add_argument("--debug-url", default="http://127.0.0.1:9238")
    parser.add_argument("--preview", type=Path)
    args = parser.parse_args()
    browser = Browser(args.debug_url)
    try:
        browser.call("Page.enable")
        browser.call("Network.enable")
        browser.call("Network.setCacheDisabled", dict(cacheDisabled=True))
        browser.call("Emulation.setDeviceMetricsOverride", dict(
            width=900, height=900, deviceScaleFactor=1, mobile=False))
        separator = "&" if "?" in args.url else "?"
        browser.call("Page.navigate", dict(url=f"{args.url}{separator}lighting-check={time.time()}"))
        browser.wait_for("document.getElementById('viewer')?.dataset.algorithm === 'iFOD2'")
        # A horizontal mirror-like square must shine toward the reflected sky
        # direction (+3,-4,+8), and dim when viewed from the opposite azimuth.
        # Its centre stays at the same screen position in both views.
        evaluate(browser, """(async () => {
          const probe = document.createElement('div');
          probe.id = 'lighting-probe';
          probe.style = 'position:fixed;left:0;top:0;width:512px;height:512px;z-index:100';
          document.body.appendChild(probe);
          const axis = {visible:false, range:[-1,1], autorange:false};
          await Plotly.newPlot(probe, [{type:'mesh3d',
            x:[-0.7,0.7,0.7,-0.7], y:[-0.7,-0.7,0.7,0.7], z:[0,0,0,0],
            i:[0,0],j:[1,2],k:[2,3],color:'white',flatshading:true,
            lighting:{ambient:0,diffuse:0,specular:1,roughness:0.2,fresnel:0.3}}],
            {paper_bgcolor:'black',margin:{l:0,r:0,t:0,b:0},scene:{bgcolor:'black',
              xaxis:axis,yaxis:axis,zaxis:axis,aspectmode:'cube',
              camera:{eye:{x:0.6,y:-0.8,z:1.6},up:{x:0,y:0,z:1}}}},
            {displayModeBar:false});
          applySkyLight(probe);
        })()""")
        reflected = np.asarray(Image.open(BytesIO(capture(browser, 512))).convert("RGB"))
        evaluate(browser, """Plotly.relayout(document.getElementById('lighting-probe'), {
          'scene.camera.eye':{x:-0.6,y:0.8,z:1.6}})""")
        opposite = np.asarray(Image.open(BytesIO(capture(browser, 512))).convert("RGB"))
        bright = float(reflected[248:264, 248:264].mean())
        dark = float(opposite[248:264, 248:264].mean())
        if not bright > max(30, dark * 3):
            raise AssertionError(f"Skylight did not stay fixed as the camera rotated: {bright=}, {dark=}")
        print(f"Fixed skylight: reflection {bright:.1f}/255, opposite view {dark:.1f}/255.", flush=True)
        evaluate(browser, """(() => {
          const probe=document.getElementById('lighting-probe');
          Plotly.purge(probe); probe.remove();
        })()""")
        if args.preview:
            browser.call("Emulation.setDeviceMetricsOverride", dict(
                width=1400, height=1400, deviceScaleFactor=1, mobile=False))
            evaluate(browser, """(async () => {
              document.querySelector('header').style.display='none';
              document.querySelector('footer').style.display='none';
              document.body.style.display='block';
              const plot=document.getElementById('viewer');
              plot.style.width='1400px'; plot.style.height='1400px';
              await Plotly.Plots.resize(plot);
              await Plotly.relayout(plot, {'scene.camera':{
                eye:{x:0.24,y:1.1,z:0.18},up:{x:0,y:0,z:1},center:{x:0,y:0,z:0.02}}});
            })()""")
            args.preview.write_bytes(capture(browser, 1400))
            print(f"Saved preview: {args.preview}", flush=True)
    finally:
        browser.connection.close()


if __name__ == "__main__":
    main()
