"use strict";

// Give the exported display trajectories a surface that can catch light.
// Radius is in anatomical millimetres; every retained centreline point and
// direction colour comes from the existing export, without resampling.
function tractMesh(trace) {
  const sides = 6;
  const radius = 0.3;
  const paths = [];
  let path = [];
  const point = index => [trace.x[index], trace.y[index], trace.z[index]];
  const subtract = (a, b) => a.map((v, i) => v - b[i]);
  const dot = (a, b) => a.reduce((sum, v, i) => sum + v * b[i], 0);
  const cross = (a, b) => [a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
  const unit = vector => {
    const length = Math.hypot(...vector);
    return length > 1e-10 ? vector.map(v => v / length) : null;
  };
  for (let index = 0; index <= trace.x.length; index++) {
    if (index === trace.x.length || !point(index).every(Number.isFinite)) {
      if (path.length > 1) paths.push(path);
      path = [];
    } else if (!path.length || unit(subtract(point(index), point(path[path.length - 1])))) {
      // Rounded exports can contain repeated points. Avoid zero-area rings.
      path.push(index);
    }
  }

  const points = paths.reduce((sum, indices) => sum + indices.length, 0);
  const vertices = points * sides;
  const faces = (points - paths.length) * sides * 2 + paths.length * (sides - 2) * 2;
  const mesh = {
    type: "mesh3d", name: trace.name,
    x: new Float32Array(vertices), y: new Float32Array(vertices), z: new Float32Array(vertices),
    i: new Uint32Array(faces), j: new Uint32Array(faces), k: new Uint32Array(faces),
    vertexcolor: new Array(vertices), flatshading: false,
    lighting: {ambient: 0.32, diffuse: 0.72, specular: 1.5, roughness: 0.2, fresnel: 0.3},
    opacity: 1, hoverinfo: "skip", showscale: false, showlegend: false
  };
  const circle = Array.from({length: sides}, (_, side) => {
    const angle = 2 * Math.PI * side / sides;
    return [radius * Math.cos(angle), radius * Math.sin(angle)];
  });
  let vertex = 0;
  let face = 0;
  const triangle = (a, b, c) => {
    mesh.i[face] = a;
    mesh.j[face] = b;
    mesh.k[face++] = c;
  };
  for (const indices of paths) {
    const first = vertex;
    let normal = null;
    for (let p = 0; p < indices.length; p++) {
      const centre = point(indices[p]);
      const previous = point(indices[Math.max(0, p - 1)]);
      const next = point(indices[Math.min(indices.length - 1, p + 1)]);
      const tangent = unit(subtract(next, previous)) || unit(subtract(centre, previous));
      // Transport the ring frame along the curve, avoiding arbitrary twists.
      if (normal) {
        const projection = dot(normal, tangent);
        normal = unit(normal.map((value, axis) => value - projection * tangent[axis]));
      }
      if (!normal) normal = unit(cross(tangent, Math.abs(tangent[2]) < 0.9 ? [0, 0, 1] : [0, 1, 0]));
      const binormal = cross(tangent, normal);
      for (const [cosine, sine] of circle) {
        mesh.x[vertex] = centre[0] + cosine * normal[0] + sine * binormal[0];
        mesh.y[vertex] = centre[1] + cosine * normal[1] + sine * binormal[1];
        mesh.z[vertex] = centre[2] + cosine * normal[2] + sine * binormal[2];
        mesh.vertexcolor[vertex++] = trace.line.color[indices[p]];
      }
      if (p > 0) {
        const start = vertex - 2 * sides;
        for (let side = 0; side < sides; side++) {
          const a = start + side;
          const b = start + (side + 1) % sides;
          triangle(a, b, a + sides);
          triangle(b, b + sides, a + sides);
        }
      }
    }
    // Close each streamline separately; never bridge the exported null gaps.
    const last = vertex - sides;
    for (let side = 1; side < sides - 1; side++) {
      triangle(first, first + side + 1, first + side);
      triangle(last, last + side, last + side + 1);
    }
  }
  return mesh;
}
