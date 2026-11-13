"""Check cortical contours in the public viewer or its bundled local preview.

Use the Chrome setup documented in viewer_geometry_check.py, then run:
python3 tests/viewer_cortex_check.py --url http://127.0.0.1:8766
"""
from pathlib import Path
import argparse
import base64
import json
import time

import numpy as np
from PIL import Image

from viewer_geometry_check import Browser

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--url", default="http://127.0.0.1:8766")
parser.add_argument("--debug-url", default="http://127.0.0.1:9238")
parser.add_argument("--out", type=Path, default=root / "results/fastsurfer")
args = parser.parse_args()
out = args.out
out.mkdir(parents=True, exist_ok=True)
browser = Browser(args.debug_url)


def evaluate(expression):
    result = browser.call("Runtime.evaluate", dict(expression=expression, awaitPromise=True, returnByValue=True))
    if "exceptionDetails" in result:
        raise RuntimeError(result["exceptionDetails"])
    return result.get("result", {}).get("value")


def capture(name):
    time.sleep(.4)
    (out / name).write_bytes(base64.b64decode(browser.call("Page.captureScreenshot", dict(format="png"))["data"]))


def next_frame(expression):
    before = int(browser.evaluate("cortex.canvas.dataset.frame"))
    evaluate(expression)
    evaluate("cortex.set({});true")
    browser.wait_for(f"Number(cortex.canvas.dataset.frame) > {before} || viewerErrors.length > 0")
    assert browser.evaluate("viewerErrors.length===0"), browser.evaluate("viewerErrors")
    assert browser.evaluate("cortex.gl.getError()===cortex.gl.NO_ERROR")


try:
    browser.call("Page.enable")
    browser.call("Network.enable")
    browser.call("Network.setCacheDisabled", dict(cacheDisabled=True))
    browser.call("Page.addScriptToEvaluateOnNewDocument", dict(source="window.viewerErrors=[];addEventListener('error',e=>viewerErrors.push(e.message));"))
    browser.call("Emulation.setDeviceMetricsOverride", dict(width=1400, height=1100, deviceScaleFactor=1, mobile=False))
    browser.call("Page.navigate", dict(url=args.url))
    browser.wait_for("Boolean(document.body?.dataset.error || viewerErrors.length || document.querySelector('canvas[data-toon-ready]'))")
    assert not browser.evaluate("document.body.dataset.error"), browser.evaluate("document.body.dataset.error")
    assert not browser.evaluate("viewerErrors"), browser.evaluate("viewerErrors")
    assert browser.evaluate("document.getElementById('mode')===null && document.getElementById('reset')===null")
    assert browser.evaluate("viewer._fullLayout.scene.camera.eye.x===0 && viewer._fullLayout.scene.camera.eye.z===0 && viewer._fullLayout.scene.camera.up.z===1")
    key_light = browser.evaluate("""(() => {
      const gl=cortex.gl,program=gl.getParameter(gl.CURRENT_PROGRAM);
      return Array.from(gl.getUniform(program,gl.getUniformLocation(program,'lightPosition')));
    })()""")
    assert key_light[0] < 0 and key_light[1] > 0 and key_light[2] > 0, "Key light must be above-left and in front"
    capture("contour_preview.png")
    timings = []
    for name, eye in [("left", dict(x=-1.5, y=.3, z=.2)), ("right", dict(x=1.5,y=.3,z=.2)),
                      ("zoom", dict(x=.15,y=.68,z=.15)), ("front", dict(x=0,y=1.45,z=0))]:
        next_frame("(async()=>{await Plotly.relayout(viewer,{'scene.camera.eye':"+json.dumps(eye)+"});return true;})()")
        timings.append(float(browser.evaluate("cortex.canvas.dataset.drawMs")))
        assert browser.evaluate("""(() => {
          const gl=cortex.gl,p=gl.getParameter(gl.CURRENT_PROGRAM),view=viewer._fullLayout.scene._scene.glplot.cameraParams.view;
          const actual=gl.getUniform(p,gl.getUniformLocation(p,'lightPosition'));
          return [0,1,2].every(row=>Math.abs(actual[row]-(view[12+row]+SKY_LIGHT_POSITION.reduce((s,v,i)=>s+view[i*4+row]*v,0)))<.00001);
        })()"""), "Contour light moved in world coordinates"
        if name in ("left", "right"):
            capture(f"contour_{name}.png")
    def set_folds(value):
        next_frame("{const input=document.getElementById('folds');input.checked="+json.dumps(value)+
                   ";input.dispatchEvent(new Event('change'));}true")

    assert browser.evaluate("document.getElementById('folds').type==='checkbox' && document.querySelector('input[type=range]')===null")
    # Inspect the displayed contour mask, including close zoom and both sides.
    evaluate("viewer._fullLayout.scene._scene.glplot.canvas.style.visibility='hidden';true")
    neutral_errors = []
    for eye in [dict(x=0,y=1.45,z=0),dict(x=.08,y=.36,z=.08),dict(x=-.55,y=.1,z=.08),dict(x=.55,y=.1,z=.08)]:
        next_frame("(async()=>{await Plotly.relayout(viewer,{'scene.camera.eye':"+json.dumps(eye)+"});return true;})()")
        capture("contour_colour_check.png")
        pixels = np.asarray(Image.open(out / "contour_colour_check.png").convert("RGB"),dtype=np.int16)[90:-45]
        chroma = int((pixels.max(axis=2)-pixels.min(axis=2)).max())
        neutral_errors.append(chroma)
        assert chroma <= 1, f"Contour ink is tinted at camera {eye}"
        assert browser.evaluate("""(()=>{
          const pixels=cortex.canvas.getContext('2d').getImageData(0,0,cortex.canvas.width,cortex.canvas.height).data;
          for(let i=0;i<pixels.length;i+=4)if(pixels[i+3] && (pixels[i]!==pixels[i+1] || pixels[i]!==pixels[i+2]))return false;
          return true;
        })()"""), "The visible contour mask contains non-grey pixels"
    (out / "contour_colour_check.png").unlink()
    next_frame("(async()=>{await Plotly.relayout(viewer,{'scene.camera.eye':{x:0,y:1.45,z:0}});return true;})()")
    evaluate("viewer._fullLayout.scene._scene.glplot.canvas.style.visibility='visible';true")

    set_folds(False)
    capture("contour_outline_check.png")
    set_folds(True)
    capture("contour_folds_check.png")
    evaluate("cortex.set({visible:false});true")
    capture("contour_hidden_check.png")
    next_frame("cortex.set({visible:true});true")
    samples = [np.asarray(Image.open(out / f"contour_{name}_check.png").convert("RGB"),dtype=np.int16)[90:-45]
               for name in ("outline", "folds", "hidden")]
    fold_pixels = int((np.max(np.abs(samples[1]-samples[0]),axis=2)>10).sum())
    assert fold_pixels > 1000, "Fold lines did not add visible interior detail"
    changed = np.max(np.abs(samples[1]-samples[2]),axis=2)>2
    rows,cols = np.nonzero(changed)
    coverage = float(changed[rows.min():rows.max()+1,cols.min():cols.max()+1].mean())
    assert coverage < .2, "Contour overlay fills the surface instead of drawing only lines"
    assert browser.evaluate("document.getElementById('shading')===null")
    for name in ("outline", "folds", "hidden"):
        (out / f"contour_{name}_check.png").unlink()
    evaluate("side.value='left';side.dispatchEvent(new Event('change'));true")
    browser.wait_for("viewer.data[0].visible && !viewer.data[1].visible")
    evaluate("side.value='both';side.dispatchEvent(new Event('change'));true")
    browser.wait_for("viewer.data[0].visible && viewer.data[1].visible")
    evaluate("document.getElementById('contours').click();true")
    assert browser.evaluate("cortex.canvas.style.display==='none'")
    next_frame("document.getElementById('contours').click();true")
    browser.call("Emulation.setDeviceMetricsOverride", dict(width=900, height=700, deviceScaleFactor=2, mobile=False))
    browser.wait_for("cortex.canvas.width === Math.round(viewer._fullLayout.scene._scene.glplot.canvas.getBoundingClientRect().width*2)")
    assert not browser.evaluate("viewerErrors"), browser.evaluate("viewerErrors")
    browser.call("Emulation.setDeviceMetricsOverride", dict(width=1400, height=1100, deviceScaleFactor=1, mobile=False))
    browser.wait_for("cortex.canvas.width === Math.round(viewer._fullLayout.scene._scene.glplot.canvas.getBoundingClientRect().width*2)")
    capture("contour_preview.png")
    report = dict(rotation_and_zoom=True, controls=True, resizing_and_retina=True, straight_initial_view=True,
                  webgl_errors=browser.evaluate("viewerErrors"), cpu_submission_ms=timings,
                  fold_pixels=fold_pixels, contour_coverage_fraction=coverage,
                  fixed_upper_left_frontal_light=True, light_in_initial_view=key_light,
                  contour_rgb_channel_difference=neutral_errors,
                  fold_checkbox=True, close_zoom_neutral_mask=True,
                  rendering="neutral grey contour mask; fine fold lines on/off; light and depth affect width only; no fill")
    (out / "viewer_check.json").write_text(json.dumps(report, indent=2)+"\n")
    print(json.dumps(report, indent=2), flush=True)
finally:
    browser.connection.close()
