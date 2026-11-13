"use strict";

// Contours from the nearest cortical surface, never from stacked transparent
// folds. Uses the same camera and physical scale as Plotly 2.32.0.
function addCortexToon(plot, surface, initial = {}) {
  const canvas = document.createElement("canvas");
  canvas.style.cssText = "position:absolute;pointer-events:none;z-index:2";
  plot.appendChild(canvas);
  // Keep GPU geometry/normal buffers offscreen. The visible layer uses only
  // their contour alpha, coloured with a single neutral Canvas 2D fill.
  const renderer = document.createElement("canvas");
  const target = canvas.getContext("2d", {alpha: true});
  const gl = renderer.getContext("webgl2", {alpha: true, antialias: false, premultipliedAlpha: true});
  if (!gl) throw Error("Cortical contours require WebGL 2.");
  if (!target) throw Error("Cortical contours require Canvas 2D.");
  const scene = plot._fullLayout.scene._scene;
  const camera = scene.glplot;
  const options = {foldLines: true, visible: true, ...initial};
  canvas.style.display = options.visible ? "block" : "none";
  const resources = [];

  function program(vertex, fragment) {
    const shaders = [[gl.VERTEX_SHADER, vertex], [gl.FRAGMENT_SHADER, fragment]].map(([type, source]) => {
      const shader = gl.createShader(type);
      gl.shaderSource(shader, source);
      gl.compileShader(shader);
      if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw Error(gl.getShaderInfoLog(shader));
      return shader;
    });
    const result = gl.createProgram();
    shaders.forEach(shader => gl.attachShader(result, shader));
    gl.linkProgram(result);
    if (!gl.getProgramParameter(result, gl.LINK_STATUS)) throw Error(gl.getProgramInfoLog(result));
    shaders.forEach(shader => gl.deleteShader(shader));
    resources.push(() => gl.deleteProgram(result));
    return result;
  }

  const geometry = program(`#version 300 es
    precision highp float;
    layout(location=0) in vec3 position;
    layout(location=1) in vec3 normal;
    uniform mat4 modelView, projection;
    uniform vec3 scale;
    out vec3 viewNormal;
    void main() {
      mat3 scaledView = mat3(modelView) * mat3(scale.x,0,0, 0,scale.y,0, 0,0,scale.z);
      vec3 n = transpose(inverse(scaledView)) * normal;
      viewNormal = n * inversesqrt(max(dot(n,n),1e-12));
      gl_Position = projection * modelView * vec4(position * scale, 1.0);
    }`, `#version 300 es
    precision highp float;
    in vec3 viewNormal;
    out vec4 color;
    void main() {
      vec3 n = viewNormal * inversesqrt(max(dot(viewNormal,viewNormal),1e-12));
      if (!gl_FrontFacing) n = -n;
      color = vec4(n * 0.5 + 0.5, 1.0);
    }`);

  const ink = program(`#version 300 es
    precision highp float;
    out vec2 uv;
    void main() {
      vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
      uv = p;
      gl_Position = vec4(p * 2.0 - 1.0, 0, 1);
    }`, `#version 300 es
    precision highp float;
    uniform sampler2D normals, depths;
    uniform mat4 projection;
    uniform vec2 pixel;
    uniform vec3 lightPosition;
    uniform vec2 depthBounds;
    uniform float millimeters, folds;
    in vec2 uv;
    out vec4 color;
    float distanceAt(vec2 p) {
      float z = texture(depths, p).r * 2.0 - 1.0;
      if (abs(projection[2][3]) > 0.5)
        return abs(-projection[3][2] / min(z + projection[2][2],-1e-7));
      return abs((z - projection[3][2]) / projection[2][2]);
    }
    vec3 positionAt(vec2 p, float depth) {
      float z = -depth;
      float w = projection[2][3] * z + projection[3][3];
      return vec3(((p * 2.0 - 1.0) * w - projection[2].xy * z - projection[3].xy)
        / vec2(projection[0][0],projection[1][1]), z);
    }
    vec3 normalAt(vec4 sampleValue) {
      // Undo the transparent border's contribution when filtering the normal map.
      vec3 n = sampleValue.xyz / max(sampleValue.a,0.001) * 2.0 - 1.0;
      return n * inversesqrt(max(dot(n,n),1e-12));
    }
    void main() {
      vec4 center = texture(normals, uv);
      vec3 n = normalAt(center);
      vec3 contourNormal = n;
      vec2 contourUV = uv;
      float bestMask = center.a;
      // Find a surface normal for silhouette pixels just outside the mesh.
      for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
          if (x == 0 && y == 0) continue;
          vec2 p = uv + vec2(x,y) * pixel * 0.75;
          vec4 other = texture(normals, p);
          if (other.a > bestMask) {
            bestMask = other.a;
            contourNormal = normalAt(other);
            contourUV = p;
          }
        }
      }
      if (bestMask < 0.001) { color = vec4(0); return; }
      float contourDepth = distanceAt(contourUV);
      vec3 toLight = lightPosition - positionAt(contourUV,contourDepth);
      vec3 lightDirection = toLight * inversesqrt(max(dot(toLight,toLight),1e-12));
      float shadow = 1.0 - max(0.0,dot(contourNormal,lightDirection));
      float depthWidth = mix(1.0,0.85,smoothstep(depthBounds.x,depthBounds.y,contourDepth));
      // Pixel widths are independent of ink colour and opacity. Interior
      // strokes stay much finer than the silhouette; shadow adds a little weight.
      float outerRadius = mix(0.50,0.68,shadow) * depthWidth;
      float innerRadius = mix(0.22,0.32,shadow) * depthWidth;
      float nearMask = center.a, farMask = center.a;
      float bend = 0.0, jump = 0.0;
      float depth = center.a > 0.99 ? distanceAt(uv) : contourDepth;
      for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
          if (x == 0 && y == 0) continue;
          vec2 offset = vec2(x,y) * pixel;
          float outerMask = texture(normals,uv + offset * outerRadius).a;
          nearMask = min(nearMask,outerMask);
          farMask = max(farMask,outerMask);
          vec2 p = uv + offset * innerRadius;
          vec4 other = texture(normals,p);
          if (center.a > 0.99 && other.a > 0.99) {
            bend = max(bend, length(n - normalAt(other)));
            jump = max(jump, abs(depth - distanceAt(p)) * millimeters);
          }
        }
      }
      float outline = smoothstep(0.12, 0.85, farMask - nearMask);
      float detail = max(smoothstep(0.34, 0.70, bend), smoothstep(2.5, 7.0, jump));
      detail *= center.a * (1.0 - outline);
      float line = max(outline * 0.83, detail * folds);
      // Only contour pixels have opacity; the surface between them is clear.
      if (isnan(line) || isinf(line)) line = 0.0;
      line = clamp(line,0.0,1.0);
      color = vec4(vec3(line),line);
    }`);

  const positions = new Float32Array(surface.x.length * 3);
  const normals = new Float32Array(positions.length);
  const indices = new Uint32Array(surface.i.length * 3);
  const minimum = [Infinity,Infinity,Infinity], maximum = [-Infinity,-Infinity,-Infinity];
  for (let v = 0; v < surface.x.length; v++) {
    positions.set([surface.x[v], surface.y[v], surface.z[v]], v * 3);
    for (let axis=0;axis<3;axis++) {
      minimum[axis] = Math.min(minimum[axis],positions[v*3+axis]);
      maximum[axis] = Math.max(maximum[axis],positions[v*3+axis]);
    }
  }
  const center = minimum.map((value,i)=>(value+maximum[i])/2);
  const halfSize = minimum.map((value,i)=>(maximum[i]-value)/2);
  for (let f = 0; f < surface.i.length; f++) {
    const a = surface.i[f], b = surface.j[f], c = surface.k[f];
    indices.set([a, b, c], f * 3);
    const ax = positions[b*3]-positions[a*3], ay = positions[b*3+1]-positions[a*3+1], az = positions[b*3+2]-positions[a*3+2];
    const bx = positions[c*3]-positions[a*3], by = positions[c*3+1]-positions[a*3+1], bz = positions[c*3+2]-positions[a*3+2];
    const nx = ay*bz-az*by, ny = az*bx-ax*bz, nz = ax*by-ay*bx;
    for (const v of [a,b,c]) { normals[v*3]+=nx; normals[v*3+1]+=ny; normals[v*3+2]+=nz; }
  }
  const vao = gl.createVertexArray();
  gl.bindVertexArray(vao);
  for (const [index, values] of [[0, positions], [1, normals]]) {
    const buffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    gl.bufferData(gl.ARRAY_BUFFER, values, gl.STATIC_DRAW);
    gl.enableVertexAttribArray(index);
    gl.vertexAttribPointer(index, 3, gl.FLOAT, false, 0, 0);
    resources.push(() => gl.deleteBuffer(buffer));
  }
  const elements = gl.createBuffer();
  gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, elements);
  gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, indices, gl.STATIC_DRAW);
  resources.push(() => gl.deleteBuffer(elements), () => gl.deleteVertexArray(vao));
  gl.bindVertexArray(null);

  function texture(filter) {
    const result = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, result);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    resources.push(() => gl.deleteTexture(result));
    return result;
  }
  const normalTexture = texture(gl.LINEAR), depthTexture = texture(gl.NEAREST);
  const framebuffer = gl.createFramebuffer();
  resources.push(() => gl.deleteFramebuffer(framebuffer));
  const uniform = (p, name) => gl.getUniformLocation(p, name);
  const geometryUniforms = Object.fromEntries(["modelView","projection","scale"].map(n => [n, uniform(geometry,n)]));
  const inkUniforms = Object.fromEntries(["normals","depths","projection","pixel","millimeters","folds","lightPosition","depthBounds"].map(n => [n, uniform(ink,n)]));
  let last = "", queued = false, destroyed = false;
  function multiply(a,b) {
    const c = new Float32Array(16);
    for (let col=0;col<4;col++) for (let row=0;row<4;row++)
      for (let k=0;k<4;k++) c[col*4+row] += a[k*4+row]*b[col*4+k];
    return c;
  }
  function draw() {
    queued = false;
    if (destroyed || !options.visible) return;
    const start = performance.now();
    const box = camera.canvas.getBoundingClientRect(), parent = plot.getBoundingClientRect();
    if (!box.width || !box.height) return;
    const {model,view,projection} = camera.cameraParams;
    // Supersampling keeps subpixel fold strokes smooth on ordinary displays too.
    const ratio = 2;
    const fingerprint = [box.width,box.height,ratio,...scene.dataScale,...model,...view,...projection,options.foldLines].join(",");
    if (fingerprint === last) return;
    last = fingerprint;
    canvas.style.left = `${box.left-parent.left}px`;
    canvas.style.top = `${box.top-parent.top}px`;
    canvas.style.width = `${box.width}px`;
    canvas.style.height = `${box.height}px`;
    const width = Math.round(box.width*ratio), height = Math.round(box.height*ratio);
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width; canvas.height = height;
      renderer.width = width; renderer.height = height;
      gl.bindTexture(gl.TEXTURE_2D, normalTexture);
      gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA8,width,height,0,gl.RGBA,gl.UNSIGNED_BYTE,null);
      gl.bindTexture(gl.TEXTURE_2D, depthTexture);
      gl.texImage2D(gl.TEXTURE_2D,0,gl.DEPTH_COMPONENT24,width,height,0,gl.DEPTH_COMPONENT,gl.UNSIGNED_INT,null);
      gl.bindFramebuffer(gl.FRAMEBUFFER,framebuffer);
      gl.framebufferTexture2D(gl.FRAMEBUFFER,gl.COLOR_ATTACHMENT0,gl.TEXTURE_2D,normalTexture,0);
      gl.framebufferTexture2D(gl.FRAMEBUFFER,gl.DEPTH_ATTACHMENT,gl.TEXTURE_2D,depthTexture,0);
      if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) !== gl.FRAMEBUFFER_COMPLETE) throw Error("Cortical contour framebuffer is incomplete.");
    }
    const mv = multiply(view,model);
    const mmScale = Math.hypot(mv[0],mv[1],mv[2])*scene.dataScale[0];
    gl.viewport(0,0,width,height);
    gl.bindFramebuffer(gl.FRAMEBUFFER,framebuffer);
    gl.enable(gl.DEPTH_TEST);
    gl.depthMask(true);
    gl.disable(gl.BLEND);
    gl.clearColor(0,0,0,0);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    gl.useProgram(geometry);
    gl.uniformMatrix4fv(geometryUniforms.modelView,false,mv);
    gl.uniformMatrix4fv(geometryUniforms.projection,false,projection);
    gl.uniform3fv(geometryUniforms.scale,scene.dataScale);
    gl.bindVertexArray(vao);
    gl.drawElements(gl.TRIANGLES,indices.length,gl.UNSIGNED_INT,0);
    gl.bindVertexArray(null);
    gl.bindFramebuffer(gl.FRAMEBUFFER,null);
    gl.disable(gl.DEPTH_TEST);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.useProgram(ink);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D,normalTexture);
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D,depthTexture);
    gl.uniform1i(inkUniforms.normals,0); gl.uniform1i(inkUniforms.depths,1);
    gl.uniformMatrix4fv(inkUniforms.projection,false,projection);
    gl.uniform2f(inkUniforms.pixel,1/box.width,1/box.height);
    const lightView = [0,1,2].map(row => view[12+row] + SKY_LIGHT_POSITION.reduce((sum,value,i)=>sum+view[i*4+row]*value,0));
    gl.uniform3fv(inkUniforms.lightPosition,lightView);
    const centerDepth = -(mv[14]+center.reduce((sum,value,i)=>sum+mv[i*4+2]*scene.dataScale[i]*value,0));
    const depthRadius = halfSize.reduce((sum,value,i)=>sum+Math.abs(mv[i*4+2]*scene.dataScale[i])*value,0);
    gl.uniform2f(inkUniforms.depthBounds,centerDepth-depthRadius,centerDepth+depthRadius);
    gl.uniform1f(inkUniforms.millimeters,1/mmScale);
    gl.uniform1f(inkUniforms.folds,options.foldLines ? 0.42 : 0);
    gl.drawArrays(gl.TRIANGLES,0,3);
    const error = gl.getError();
    if (error !== gl.NO_ERROR) throw Error(`Cortical contour rendering failed (${error}).`);
    target.globalCompositeOperation = "copy";
    target.drawImage(renderer,0,0);
    target.globalCompositeOperation = "source-in";
    target.fillStyle = "rgb(158,158,158)";
    target.fillRect(0,0,width,height);
    target.globalCompositeOperation = "source-over";
    canvas.dataset.frame = String(Number(canvas.dataset.frame || 0)+1);
    canvas.dataset.drawMs = (performance.now()-start).toFixed(1);
    canvas.dataset.toonReady = "true";
  }
  function schedule() {
    if (!queued && !destroyed && options.visible) { queued=true; requestAnimationFrame(draw); }
  }
  const previous = camera.onrender;
  function onRender(...args) { if (previous) previous.apply(this,args); schedule(); }
  camera.onrender = onRender;
  const observer = new ResizeObserver(() => { last=""; schedule(); });
  observer.observe(plot);
  schedule();
  return {
    canvas, gl,
    set(values) {
      Object.assign(options,values);
      canvas.style.display = options.visible ? "block" : "none";
      last=""; schedule();
    },
    destroy() {
      destroyed=true; observer.disconnect();
      if (camera.onrender === onRender) camera.onrender=previous;
      resources.reverse().forEach(dispose=>dispose());
      gl.getExtension("WEBGL_lose_context")?.loseContext();
      canvas.remove();
    }
  };
}
