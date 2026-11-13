/* global Plotly, tractMesh, applySkyLight, addCortexToon */
"use strict";

const viewer = document.getElementById("viewer");
const algorithm = document.getElementById("algorithm");
const side = document.getElementById("side");
const contours = document.getElementById("contours");
const folds = document.getElementById("folds");
const status = document.getElementById("status");
const frontCamera = () => ({eye: {x: 0, y: 1.45, z: 0}, up: {x: 0, y: 0, z: 1}});
// The local file preview embeds the same data used by the hosted viewer.
const cache = new Map(Object.entries(window.FAT_VIEWER_DATA || {}));
let surface, cortex;
let current = "iFOD2";
let ready = false;

async function loadJSON(name) {
  if (!cache.has(name)) {
    const response = await fetch(`data/${name}.json`);
    if (!response.ok) throw new Error(`Could not load ${name} (${response.status})`);
    cache.set(name, await response.json());
  }
  return cache.get(name);
}

function visibility() {
  return [side.value !== "right", side.value !== "left"];
}

async function showAlgorithm() {
  algorithm.disabled = true;
  const requested = algorithm.value;
  status.textContent = `Loading ${requested}…`;
  try {
    const lines = await loadJSON(requested);
    const tracts = lines.map(tractMesh);
    const visible = visibility();
    const traces = tracts.map((trace, i) => ({...trace, visible: visible[i]}));
    const layout = {
      paper_bgcolor: "black", plot_bgcolor: "black", margin: {l: 0, r: 0, t: 0, b: 0},
      showlegend: false, uirevision: "fat-camera",
      // Keep one physical scale for all layers: axis spans are 178, 210 and 187 mm.
      // Plotly's "data" aspect mode changes proportions when a trace is hidden.
      scene: {bgcolor: "black", aspectmode: "manual",
        aspectratio: {x: 178 / 210, y: 1, z: 187 / 210},
        camera: ready ? structuredClone(viewer._fullLayout.scene.camera) : frontCamera(),
        xaxis: {visible: false, autorange: false, range: [-88, 90]},
        yaxis: {visible: false, autorange: false, range: [-100, 110]},
        zaxis: {visible: false, autorange: false, range: [-95, 92]}}
    };
    if (cortex) { cortex.destroy(); cortex = null; }
    await Plotly.react(viewer, traces, layout, {displayModeBar: false, scrollZoom: true, responsive: true});
    applySkyLight(viewer);
    cortex = addCortexToon(viewer, surface, {foldLines: folds.checked, visible: contours.checked});
    ready = true;
    current = requested;
    viewer.dataset.algorithm = current;
    status.textContent = "500 of 2000 streamlines per side · direction RGB";
  } catch (error) {
    algorithm.value = current;
    status.textContent = `${error.message}. Reload the page to retry.`;
  } finally {
    algorithm.disabled = false;
  }
}

algorithm.addEventListener("change", showAlgorithm);
side.addEventListener("change", async () => {
  if (ready) {
    await Plotly.restyle(viewer, {visible: visibility()});
    applySkyLight(viewer);
  }
});
folds.addEventListener("change", () => cortex?.set({foldLines: folds.checked}));
contours.addEventListener("change", () => cortex?.set({visible: contours.checked}));
viewer.addEventListener("plotly_webglcontextlost", () => {
  status.textContent = "The 3D graphics context was lost. Reload the page.";
});

(async () => {
  try {
    if (typeof Plotly === "undefined") throw new Error("The 3D library could not load");
    surface = await loadJSON("cortex");
    await showAlgorithm();
  } catch (error) {
    status.textContent = `${error.message}. Reload the page to retry.`;
  }
})();
