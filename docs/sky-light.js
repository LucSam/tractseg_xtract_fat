"use strict";

// Plotly 2.32.0's mesh shader mixes view-space positions with object-space
// light/eye coordinates. Keep lighting in world space instead: a distant
// upper-left, frontal light stays put, and only the eye moves when the scene is rotated.
// This small adapter targets the bundled Plotly renderer; keep the browser
// lighting check when upgrading it. Geometry and material shading stay intact.
// World coordinates: projects above-left in the viewer's initial frontal view.
// Contour rendering uses this same position so lines and tubes agree.
const SKY_LIGHT_POSITION = Object.freeze([6.0, 4.0, 7.0]);

const skyLightVertexShader = `
precision highp float;
attribute vec3 position, normal;
attribute vec4 color;
attribute vec2 uv;
uniform mat4 model, view, projection, inverseModel;
varying vec3 f_normal, f_lightDirection, f_eyeDirection, f_data;
varying vec4 f_color;
varying vec2 f_uv;

void main() {
  vec4 worldPosition = model * vec4(position, 1.0);
  gl_Position = projection * view * worldPosition;
  vec3 skyPosition = vec3(${SKY_LIGHT_POSITION.map(value => value.toFixed(1)).join(", ")});
  vec3 eyeWorld = -view[3].xyz * mat3(view);
  f_lightDirection = skyPosition - worldPosition.xyz;
  f_eyeDirection = eyeWorld - worldPosition.xyz;
  f_normal = normalize((vec4(normal, 0.0) * inverseModel).xyz);
  f_color = color;
  f_data = position;
  f_uv = uv;
}
`;

const skyLightShaders = new WeakSet();

function applySkyLight(plot) {
  const scene = plot._fullLayout.scene._scene;
  for (const trace of Object.values(scene.traces)) {
    const mesh = trace.mesh;
    const shader = mesh.triShader;
    if (skyLightShaders.has(shader)) continue;
    const attributes = Object.entries(shader.types.attributes).map(([name, type]) => ({
      name, type, location: shader.attributes[name].location
    }));
    shader.update(skyLightVertexShader, mesh.gl.getShaderSource(shader.fragShader), null, attributes);
    skyLightShaders.add(shader);
  }
  scene.glplot.redraw();
}
