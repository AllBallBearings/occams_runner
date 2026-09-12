const canvas = document.getElementById("scene");
const modelSelect = document.getElementById("modelSelect");
const spinToggle = document.getElementById("spinToggle");
const usdzLink = document.getElementById("usdzLink");
const statusEl = document.getElementById("status");
const assetNameEl = document.getElementById("assetName");
const voxelCountEl = document.getElementById("voxelCount");
const sourceStateEl = document.getElementById("sourceState");
const coinCropToggle = document.getElementById("coinCropToggle");
const referenceFrame = document.getElementById("referenceFrame");

const gl = canvas.getContext("webgl2", { antialias: true });
if (!gl) {
  statusEl.textContent = "This browser does not support WebGL2.";
  throw new Error("WebGL2 unavailable");
}

const vertexShader = `#version 300 es
precision highp float;

in vec3 aPosition;
in vec3 aNormal;
in vec3 iOffset;
in vec3 iColor;
in float iOpacity;
in float iEmissive;

uniform mat4 uProjection;
uniform mat4 uView;
uniform mat4 uModel;
uniform float uVoxelScale;

out vec3 vColor;
out vec3 vNormal;
out vec3 vWorldPosition;
out float vOpacity;
out float vEmissive;

void main() {
  vec3 local = (aPosition + iOffset) * uVoxelScale;
  vec4 world = uModel * vec4(local, 1.0);
  vWorldPosition = world.xyz;
  vNormal = mat3(uModel) * aNormal;
  vColor = iColor;
  vOpacity = iOpacity;
  vEmissive = iEmissive;
  gl_Position = uProjection * uView * world;
}
`;

const fragmentShader = `#version 300 es
precision highp float;

in vec3 vColor;
in vec3 vNormal;
in vec3 vWorldPosition;
in float vOpacity;
in float vEmissive;

uniform vec3 uLightDirection;
uniform vec3 uFillDirection;

out vec4 outColor;

void main() {
  vec3 normal = normalize(vNormal);
  float key = max(dot(normal, normalize(uLightDirection)), 0.0);
  float fill = max(dot(normal, normalize(uFillDirection)), 0.0);
  float rim = pow(1.0 - max(dot(normal, normalize(vec3(0.0, 0.15, 1.0))), 0.0), 2.0);
  vec3 lit = vColor * (0.30 + key * 0.72 + fill * 0.20 + vEmissive) + vec3(1.0, 0.88, 0.50) * rim * (0.10 + vEmissive * 0.22);
  outColor = vec4(lit, vOpacity);
}
`;

let program = createProgram(vertexShader, fragmentShader);
const previewParams = new URLSearchParams(window.location.search);
const angleParam = previewParams.get("angle");
const fixedRotation = angleParam === null ? null : Number(angleParam) * Math.PI / 180;
let state = {
  payload: null,
  instanceCount: 0,
  lastSourceMtime: 0,
  selected: previewParams.get("model") || "VoxelRubyGem",
  spinning: fixedRotation === null || !Number.isFinite(fixedRotation),
  rotation: Number.isFinite(fixedRotation) ? fixedRotation : 0,
  orbitX: 0,
  orbitY: 0.18,
  distance: 4.6,
  drag: null,
};

const cube = createCube();
const vao = gl.createVertexArray();
gl.bindVertexArray(vao);
bindStaticAttribute("aPosition", cube.positions, 3);
bindStaticAttribute("aNormal", cube.normals, 3);
const offsetBuffer = bindInstanceAttribute("iOffset", 3);
const colorBuffer = bindInstanceAttribute("iColor", 3);
const opacityBuffer = bindInstanceAttribute("iOpacity", 1);
const emissiveBuffer = bindInstanceAttribute("iEmissive", 1);
gl.bindVertexArray(null);

const uniforms = {
  projection: gl.getUniformLocation(program, "uProjection"),
  view: gl.getUniformLocation(program, "uView"),
  model: gl.getUniformLocation(program, "uModel"),
  voxelScale: gl.getUniformLocation(program, "uVoxelScale"),
  lightDirection: gl.getUniformLocation(program, "uLightDirection"),
  fillDirection: gl.getUniformLocation(program, "uFillDirection"),
};

gl.enable(gl.DEPTH_TEST);
gl.enable(gl.CULL_FACE);
gl.cullFace(gl.BACK);
gl.enable(gl.BLEND);
gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

init();
requestAnimationFrame(draw);

async function init() {
  const response = await fetch("/api/models", { cache: "no-store" });
  const data = await response.json();
  modelSelect.innerHTML = "";
  for (const name of data.models) {
    const option = document.createElement("option");
    option.value = name;
    option.textContent = name.replace("Voxel", "Voxel ");
    modelSelect.append(option);
  }
  state.selected = availableModelName(data.models, state.selected);
  modelSelect.value = state.selected;
  spinToggle.textContent = state.spinning ? "Pause" : "Spin";
  await loadModel(state.selected);
  setInterval(checkForUpdates, 900);
}

async function loadModel(name) {
  statusEl.textContent = "Loading...";
  const response = await fetch(`/api/model?name=${encodeURIComponent(name)}`, { cache: "no-store" });
  const payload = await response.json();
  if (!response.ok) {
    throw new Error(payload.error || "Unable to load model");
  }

  state.payload = payload;
  state.selected = payload.name;
  state.lastSourceMtime = payload.sourceMtime;
  state.instanceCount = payload.voxels.length;

  const center = {
    x: (payload.bounds.x[0] + payload.bounds.x[1]) * 0.5,
    y: (payload.bounds.y[0] + payload.bounds.y[1]) * 0.5,
    z: (payload.bounds.z[0] + payload.bounds.z[1]) * 0.5,
  };
  const offsets = new Float32Array(payload.voxels.length * 3);
  const colors = new Float32Array(payload.voxels.length * 3);
  const opacities = new Float32Array(payload.voxels.length);
  const emissions = new Float32Array(payload.voxels.length);

  payload.voxels.forEach((voxel, index) => {
    const offsetIndex = index * 3;
    offsets[offsetIndex] = voxel.x - center.x;
    offsets[offsetIndex + 1] = voxel.y - center.y;
    offsets[offsetIndex + 2] = voxel.z - center.z;

    const material = payload.palette[voxel.material] || { color: [0.75, 0.75, 0.75] };
    colors[offsetIndex] = material.color[0];
    colors[offsetIndex + 1] = material.color[1];
    colors[offsetIndex + 2] = material.color[2];
    opacities[index] = material.opacity ?? 1.0;
    emissions[index] = material.emissive ?? 0.0;
  });

  gl.bindBuffer(gl.ARRAY_BUFFER, offsetBuffer);
  gl.bufferData(gl.ARRAY_BUFFER, offsets, gl.DYNAMIC_DRAW);
  gl.bindBuffer(gl.ARRAY_BUFFER, colorBuffer);
  gl.bufferData(gl.ARRAY_BUFFER, colors, gl.DYNAMIC_DRAW);
  gl.bindBuffer(gl.ARRAY_BUFFER, opacityBuffer);
  gl.bufferData(gl.ARRAY_BUFFER, opacities, gl.DYNAMIC_DRAW);
  gl.bindBuffer(gl.ARRAY_BUFFER, emissiveBuffer);
  gl.bufferData(gl.ARRAY_BUFFER, emissions, gl.DYNAMIC_DRAW);

  const extents = [
    payload.bounds.x[1] - payload.bounds.x[0] + 1,
    payload.bounds.y[1] - payload.bounds.y[0] + 1,
    payload.bounds.z[1] - payload.bounds.z[0] + 1,
  ];
  state.distance = Math.max(1.25, Math.max(...extents) * payload.unit * 2.4);

  assetNameEl.textContent = payload.name;
  voxelCountEl.textContent = payload.voxelCount.toLocaleString();
  sourceStateEl.textContent = new Date(payload.sourceMtime * 1000).toLocaleTimeString();
  usdzLink.href = `/usdz/${payload.usdz}`;
  statusEl.textContent = "Live";
}

async function checkForUpdates() {
  try {
    const response = await fetch("/api/models", { cache: "no-store" });
    const data = await response.json();
    state.selected = availableModelName(data.models, state.selected);
    modelSelect.value = state.selected;
    if (data.sourceMtime !== state.lastSourceMtime) {
      await loadModel(state.selected);
      statusEl.textContent = "Reloaded from generator";
    }
  } catch (error) {
    statusEl.textContent = "Waiting for preview server";
  }
}

modelSelect.addEventListener("change", () => loadModel(modelSelect.value));
spinToggle.addEventListener("click", () => {
  state.spinning = !state.spinning;
  spinToggle.textContent = state.spinning ? "Pause" : "Spin";
});
coinCropToggle.addEventListener("click", () => {
  referenceFrame.classList.toggle("coin-crop");
});

canvas.addEventListener("pointerdown", (event) => {
  canvas.setPointerCapture(event.pointerId);
  state.drag = { x: event.clientX, y: event.clientY, orbitX: state.orbitX, orbitY: state.orbitY };
});
canvas.addEventListener("pointermove", (event) => {
  if (!state.drag) return;
  const dx = event.clientX - state.drag.x;
  const dy = event.clientY - state.drag.y;
  state.orbitX = state.drag.orbitX + dx * 0.008;
  state.orbitY = clamp(state.drag.orbitY + dy * 0.006, -1.15, 1.15);
});
canvas.addEventListener("pointerup", () => {
  state.drag = null;
});
canvas.addEventListener("wheel", (event) => {
  event.preventDefault();
  state.distance = clamp(state.distance + event.deltaY * 0.004, 1.8, 12.0);
}, { passive: false });

function draw(now) {
  resizeCanvas();
  if (state.spinning && !state.drag) {
    state.rotation = now * 0.00065;
  }

  gl.viewport(0, 0, canvas.width, canvas.height);
  gl.clearColor(0.075, 0.078, 0.086, 1);
  gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

  if (state.payload) {
    const aspect = canvas.width / Math.max(1, canvas.height);
    const projection = perspective(Math.PI / 4, aspect, 0.01, 100);
    const eye = orbitCamera(state.orbitX, state.orbitY, state.distance);
    const view = lookAt(eye, [0, 0, 0], [0, 1, 0]);
    const bob = Math.sin(now * 0.003) * 0.10;
    const model = multiply(translate(0, bob, 0), rotateY(state.rotation));

    gl.useProgram(program);
    gl.uniformMatrix4fv(uniforms.projection, false, projection);
    gl.uniformMatrix4fv(uniforms.view, false, view);
    gl.uniformMatrix4fv(uniforms.model, false, model);
    gl.uniform1f(uniforms.voxelScale, state.payload.unit * (state.payload.cubeScale ?? 1.0));
    gl.uniform3f(uniforms.lightDirection, -0.35, 0.88, 0.42);
    gl.uniform3f(uniforms.fillDirection, 0.8, 0.28, -0.55);

    gl.bindVertexArray(vao);
    gl.drawArraysInstanced(gl.TRIANGLES, 0, cube.vertexCount, state.instanceCount);
    gl.bindVertexArray(null);
  }

  requestAnimationFrame(draw);
}

function createProgram(vertexSource, fragmentSource) {
  const vertex = compileShader(gl.VERTEX_SHADER, vertexSource);
  const fragment = compileShader(gl.FRAGMENT_SHADER, fragmentSource);
  const linked = gl.createProgram();
  gl.attachShader(linked, vertex);
  gl.attachShader(linked, fragment);
  gl.linkProgram(linked);
  if (!gl.getProgramParameter(linked, gl.LINK_STATUS)) {
    throw new Error(gl.getProgramInfoLog(linked));
  }
  return linked;
}

function compileShader(type, source) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    throw new Error(gl.getShaderInfoLog(shader));
  }
  return shader;
}

function bindStaticAttribute(name, data, size) {
  const location = gl.getAttribLocation(program, name);
  const buffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(data), gl.STATIC_DRAW);
  gl.enableVertexAttribArray(location);
  gl.vertexAttribPointer(location, size, gl.FLOAT, false, 0, 0);
  return buffer;
}

function bindInstanceAttribute(name, size) {
  const location = gl.getAttribLocation(program, name);
  const buffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
  gl.enableVertexAttribArray(location);
  gl.vertexAttribPointer(location, size, gl.FLOAT, false, 0, 0);
  gl.vertexAttribDivisor(location, 1);
  return buffer;
}

function createCube() {
  const faces = [
    [[0, 0, 1], [-0.5, -0.5, 0.5], [0.5, -0.5, 0.5], [0.5, 0.5, 0.5], [-0.5, 0.5, 0.5]],
    [[0, 0, -1], [0.5, -0.5, -0.5], [-0.5, -0.5, -0.5], [-0.5, 0.5, -0.5], [0.5, 0.5, -0.5]],
    [[1, 0, 0], [0.5, -0.5, 0.5], [0.5, -0.5, -0.5], [0.5, 0.5, -0.5], [0.5, 0.5, 0.5]],
    [[-1, 0, 0], [-0.5, -0.5, -0.5], [-0.5, -0.5, 0.5], [-0.5, 0.5, 0.5], [-0.5, 0.5, -0.5]],
    [[0, 1, 0], [-0.5, 0.5, 0.5], [0.5, 0.5, 0.5], [0.5, 0.5, -0.5], [-0.5, 0.5, -0.5]],
    [[0, -1, 0], [-0.5, -0.5, -0.5], [0.5, -0.5, -0.5], [0.5, -0.5, 0.5], [-0.5, -0.5, 0.5]],
  ];
  const positions = [];
  const normals = [];
  for (const face of faces) {
    const normal = face[0];
    const points = face.slice(1);
    for (const index of [0, 1, 2, 0, 2, 3]) {
      positions.push(...points[index]);
      normals.push(...normal);
    }
  }
  return { positions, normals, vertexCount: positions.length / 3 };
}

function resizeCanvas() {
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  const width = Math.floor(canvas.clientWidth * dpr);
  const height = Math.floor(canvas.clientHeight * dpr);
  if (canvas.width !== width || canvas.height !== height) {
    canvas.width = width;
    canvas.height = height;
  }
}

function orbitCamera(xAngle, yAngle, distance) {
  const cosY = Math.cos(yAngle);
  return [
    Math.sin(xAngle) * cosY * distance,
    Math.sin(yAngle) * distance,
    Math.cos(xAngle) * cosY * distance,
  ];
}

function perspective(fovy, aspect, near, far) {
  const f = 1 / Math.tan(fovy / 2);
  const nf = 1 / (near - far);
  return new Float32Array([
    f / aspect, 0, 0, 0,
    0, f, 0, 0,
    0, 0, (far + near) * nf, -1,
    0, 0, (2 * far * near) * nf, 0,
  ]);
}

function lookAt(eye, center, up) {
  const z = normalize(subtract(eye, center));
  const x = normalize(cross(up, z));
  const y = cross(z, x);
  return new Float32Array([
    x[0], y[0], z[0], 0,
    x[1], y[1], z[1], 0,
    x[2], y[2], z[2], 0,
    -dot(x, eye), -dot(y, eye), -dot(z, eye), 1,
  ]);
}

function rotateX(angle) {
  const c = Math.cos(angle);
  const s = Math.sin(angle);
  return new Float32Array([
    1, 0, 0, 0,
    0, c, s, 0,
    0, -s, c, 0,
    0, 0, 0, 1,
  ]);
}

function rotateY(angle) {
  const c = Math.cos(angle);
  const s = Math.sin(angle);
  return new Float32Array([
    c, 0, -s, 0,
    0, 1, 0, 0,
    s, 0, c, 0,
    0, 0, 0, 1,
  ]);
}

function translate(x, y, z) {
  return new Float32Array([
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    x, y, z, 1,
  ]);
}

function multiply(a, b) {
  const out = new Float32Array(16);
  for (let row = 0; row < 4; row += 1) {
    for (let col = 0; col < 4; col += 1) {
      out[col * 4 + row] =
        a[0 * 4 + row] * b[col * 4 + 0] +
        a[1 * 4 + row] * b[col * 4 + 1] +
        a[2 * 4 + row] * b[col * 4 + 2] +
        a[3 * 4 + row] * b[col * 4 + 3];
    }
  }
  return out;
}

function subtract(a, b) {
  return [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
}

function cross(a, b) {
  return [
    a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2],
    a[0] * b[1] - a[1] * b[0],
  ];
}

function dot(a, b) {
  return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

function normalize(v) {
  const length = Math.hypot(v[0], v[1], v[2]) || 1;
  return [v[0] / length, v[1] / length, v[2] / length];
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function availableModelName(models, requested) {
  if (models.includes(requested)) return requested;
  if (requested === "VoxelIceSword" && models.includes("VoxelSword")) return "VoxelSword";
  if (models.includes("VoxelRubyGem")) return "VoxelRubyGem";
  return models[0];
}
