// Run with: node --test tests/viewer_mesh.test.cjs
const assert = require("node:assert/strict");
const {readFileSync} = require("node:fs");
const {join} = require("node:path");
const {test} = require("node:test");
const {runInNewContext} = require("node:vm");

const root = join(__dirname, "..");
const tractMesh = runInNewContext(readFileSync(join(root, "docs/tract-mesh.js"), "utf8") + "\ntractMesh");
const axes = ["x", "y", "z"];

function checkMesh(trace, expectedPaths) {
  const original = JSON.stringify(trace);
  const mesh = tractMesh(trace);
  assert.equal(JSON.stringify(trace), original, "Display conversion must not modify source trajectories");
  assert.equal(mesh.type, "mesh3d");
  assert.equal(mesh.name, trace.name);
  const vertexPaths = [];
  let path = -1;
  let previous = null;
  let vertex = 0;
  for (let point = 0; point < trace.x.length; point++) {
    const centre = axes.map(axis => trace[axis][point]);
    if (!centre.every(Number.isFinite)) { previous = null; continue; }
    if (previous && centre.every((value, axis) => value === previous[axis])) continue;
    if (!previous) path++;
    previous = centre;
    const mean = [0, 0, 0];
    for (let side = 0; side < 6; side++, vertex++) {
      const offset = axes.map((axis, dimension) => {
        const value = mesh[axis][vertex];
        assert.ok(Number.isFinite(value));
        mean[dimension] += value / 6;
        return value - centre[dimension];
      });
      assert.ok(Math.abs(Math.hypot(...offset) - 0.3) < 1e-5, "Tube radius must stay constant in mm");
      assert.equal(mesh.vertexcolor[vertex], trace.line.color[point]);
      vertexPaths.push(path);
    }
    assert.ok(mean.every((value, axis) => Math.abs(value - centre[axis]) < 1e-5),
      "Tube centres must follow the original anatomical coordinates");
  }
  assert.equal(path + 1, expectedPaths);
  assert.equal(mesh.x.length, vertex);
  assert.equal(mesh.y.length, vertex);
  assert.equal(mesh.z.length, vertex);
  assert.equal(mesh.vertexcolor.length, vertex);
  assert.equal(mesh.i.length, mesh.j.length);
  assert.equal(mesh.i.length, mesh.k.length);
  for (let face = 0; face < mesh.i.length; face++) {
    const indices = [mesh.i[face], mesh.j[face], mesh.k[face]];
    assert.ok(indices.every(index => index < vertex));
    assert.equal(new Set(indices).size, 3);
    assert.ok(indices.every(index => vertexPaths[index] === vertexPaths[indices[0]]),
      "Separate streamlines must never be joined by a triangle");
  }
}

test("rings handle axis-aligned paths, duplicate points, reversals and null gaps", () => {
  const points = [[0, 0, 0], [0, 0, 0], [0, 0, 1], [0, 0, 2], [0, 0, 1], null,
    [4, 0, 0], [5, 0, 0], [6, 1, 0], [6, 2, 1]];
  const trace = {name: "synthetic", line: {color: points.map(() => "rgb(80,120,200)")}};
  axes.forEach((axis, index) => { trace[axis] = points.map(point => point ? point[index] : null); });
  checkMesh(trace, 2);
});

test("empty traces and isolated points produce no surface", () => {
  const mesh = tractMesh({name: "empty", x: [null, 1, null], y: [null, 2, null],
    z: [null, 3, null], line: {color: []}});
  assert.equal(mesh.x.length, 0);
  assert.equal(mesh.i.length, 0);
});

for (const algorithm of ["iFOD2", "SD_STREAM", "FACT", "Tensor_Det", "Tensor_Prob"]) {
  test(`${algorithm}: preserve all 500 trajectories and direction colours per side`, () => {
    const traces = JSON.parse(readFileSync(join(root, `docs/data/${algorithm}.json`), "utf8"));
    for (const trace of traces) checkMesh(trace, 500);
  });
}
