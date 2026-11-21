import * as THREE from './vendor/three.module.js';
import GUI from './vendor/lil-gui.esm.min.js';

THREE.ColorManagement.enabled = false;

const D2R = Math.PI / 180;

function load(key, def) {
  try {
    const v = localStorage.getItem('kopfkino.' + key);
    return v === null ? def : JSON.parse(v);
  } catch (e) {
    return def;
  }
}
function save(key, v) {
  try { localStorage.setItem('kopfkino.' + key, JSON.stringify(v)); } catch (e) {}
}

let head = { yaw: 0, pitch: 0, roll: 0 };
let raw = [0, 0, 0];
let hz = 0, sensor = '-', lastFrame = 0;
let bridgeUp = false, status = null, cfg = null;

const mouse = { yaw: 0, pitch: 0, down: false, x: 0, y: 0 };
let flying = true;
let showUI = true;
let response = load('response', 22);
let fov = load('fov', 70);

const isLive = () => performance.now() - lastFrame < 1500;

const es = new EventSource('/events');
es.onopen = () => { bridgeUp = true; };
es.onerror = () => { bridgeUp = false; };
es.onmessage = (e) => {
  const f = JSON.parse(e.data);
  const now = performance.now();
  head = { yaw: f.yaw, pitch: f.pitch, roll: f.roll };
  raw = f.raw;
  hz = f.hz;
  sensor = f.sensor;
  lastFrame = now;
};
es.addEventListener('status', (e) => { status = JSON.parse(e.data); bridgeUp = true; });
es.addEventListener('config', (e) => onConfig(JSON.parse(e.data)));
es.addEventListener('calib', (e) => onCalib(JSON.parse(e.data)));

async function post(path, body = {}) {
  const r = await fetch(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  if (!r.ok) throw new Error(path + ' ' + r.status);
  return r.json();
}

let patch = {}, patchTimer;
function setConfig(p) {
  Object.assign(patch, p);
  clearTimeout(patchTimer);
  patchTimer = setTimeout(() => {
    post('/api/config', patch).catch((err) => message('save failed: ' + err.message));
    patch = {};
  }, 120);
}

function recenter() {
  mouse.yaw = mouse.pitch = 0;
  post('/api/recenter').catch(() => {});
}

const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
renderer.setSize(innerWidth, innerHeight);
renderer.outputColorSpace = THREE.LinearSRGBColorSpace;
document.body.prepend(renderer.domElement);

const FOG = 0xbfd5e8;
const scene = new THREE.Scene();
scene.fog = new THREE.Fog(FOG, 1800, 13500);
scene.background = new THREE.Color(FOG);

const camera = new THREE.PerspectiveCamera(fov, innerWidth / innerHeight, 0.03, 30000);

const SUN_DIR = new THREE.Vector3(0.45, 0.5, -0.74).normalize();
scene.add(new THREE.HemisphereLight(0xdcecff, 0x6b5f4a, 1.25));
const sun = new THREE.DirectionalLight(0xfff1dc, 2.1);
sun.position.copy(SUN_DIR).multiplyScalar(1000);
scene.add(sun);

const sky = new THREE.Mesh(
  new THREE.SphereGeometry(20000, 48, 24),
  new THREE.ShaderMaterial({
    side: THREE.BackSide,
    depthWrite: false,
    fog: false,
    uniforms: {
      top: { value: new THREE.Color(0x2f6fc0) },
      horizon: { value: new THREE.Color(FOG) },
      sunDir: { value: SUN_DIR },
    },
    vertexShader: `
      varying vec3 vDir;
      void main() {
        vDir = normalize(position);
        gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
      }`,
    fragmentShader: `
      uniform vec3 top, horizon, sunDir;
      varying vec3 vDir;
      void main() {
        vec3 d = normalize(vDir);
        vec3 col = mix(horizon, top, pow(max(d.y, 0.0), 0.55));
        float s = max(dot(d, sunDir), 0.0);
        col += vec3(1.0, 0.95, 0.85) * smoothstep(0.9993, 0.9997, s);
        col += vec3(1.0, 0.85, 0.6) * pow(s, 12.0) * 0.35;
        gl_FragColor = vec4(col, 1.0);
      }`,
  }),
);
sky.renderOrder = -1;
scene.add(sky);

function hash2(ix, iy) {
  let h = Math.imul(ix | 0, 374761393) ^ Math.imul(iy | 0, 668265263);
  h = Math.imul(h ^ (h >>> 13), 1274126177);
  h ^= h >>> 16;
  return (h >>> 0) / 4294967296;
}

function noise(x, y) {
  const ix = Math.floor(x), iy = Math.floor(y);
  const fx = x - ix, fy = y - iy;
  const ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy);
  const a = hash2(ix, iy), b = hash2(ix + 1, iy), c = hash2(ix, iy + 1), d = hash2(ix + 1, iy + 1);
  return a + (b - a) * ux + (c - a) * uy + (a - b - c + d) * ux * uy;
}

function fbm(x, y, oct) {
  let sum = 0, amp = 0.5, norm = 0, f = 1;
  for (let i = 0; i < oct; i++) {
    sum += amp * noise(x * f + i * 31.7, y * f - i * 17.3);
    norm += amp;
    amp *= 0.5;
    f *= 2.03;
  }
  return sum / norm;
}

function ridged(x, y, oct) {
  let sum = 0, amp = 0.5, norm = 0, f = 1;
  for (let i = 0; i < oct; i++) {
    const n = 1 - Math.abs(noise(x * f, y * f) * 2 - 1);
    sum += amp * n * n;
    norm += amp;
    amp *= 0.5;
    f *= 2.1;
  }
  return sum / norm;
}

function smoothstep(a, b, x) {
  const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
}

function rng(seed) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const riverX = (z) => 150 * Math.sin(z * 0.0011) + 60 * Math.sin(z * 0.0031 + 1.3);

function height(x, z) {
  const d = Math.abs(x - riverX(z));
  const bank = smoothstep(25, 180, d);
  const valley = smoothstep(280, 2300, d);
  const n = fbm(x * 0.00055, z * 0.00055, 5);
  const r = ridged(x * 0.0009 + 17, z * 0.0009 - 5, 4);
  const mountains = valley * (250 + Math.max(0, n - 0.3) * 2700 + r * 900) + valley * valley * 350;
  return -9 + bank * 13 + fbm(x * 0.006, z * 0.006, 2) * 12 * bank + mountains;
}

const SAND = new THREE.Color(0xcdbb8c), GRASS = new THREE.Color(0x5e8f3c), MEADOW = new THREE.Color(0x86a84e);
const FOREST = new THREE.Color(0x2e5729), ROCK = new THREE.Color(0x7d776d), ROCK2 = new THREE.Color(0x5b5852);
const SNOW = new THREE.Color(0xf1f4f7);

function groundColor(h, slope, j, out) {
  if (h < 2) out.copy(SAND);
  else if (h < 200) out.copy(GRASS).lerp(MEADOW, j);
  else if (h < 650) out.copy(GRASS).lerp(FOREST, smoothstep(200, 450, h));
  else if (h < 1450) out.copy(FOREST).lerp(ROCK, smoothstep(650, 950, h)).lerp(ROCK2, j * 0.5);
  else out.copy(ROCK).lerp(SNOW, smoothstep(1450, 1650, h + j * 120));
  if (slope > 0.55 && h > 3) out.lerp(ROCK2, smoothstep(0.55, 1.1, slope) * 0.8);
  return out.multiplyScalar(0.92 + j * 0.16);
}

let travelled = 0;
const SPEED = 75;
const ALT = 430;

const CHUNK_D = 2000, CHUNK_W = 14000, NCHUNKS = 7, TREES = 420;
const terrainMat = new THREE.MeshLambertMaterial({ vertexColors: true, flatShading: true });
const treeGeo = new THREE.ConeGeometry(7, 26, 6).translate(0, 11, 0);
const treeMat = new THREE.MeshLambertMaterial({ color: 0x24471f, flatShading: true });
const mat4 = new THREE.Matrix4();
const HIDE = new THREE.Matrix4().makeScale(0, 0, 0);
const col = new THREE.Color();

class Chunk {
  constructor() {
    this.geo = new THREE.PlaneGeometry(CHUNK_W, CHUNK_D, 160, 24).rotateX(-Math.PI / 2);
    this.base = Float32Array.from(this.geo.attributes.position.array);
    this.geo.setAttribute('color', new THREE.BufferAttribute(new Float32Array(this.base.length), 3));
    this.mesh = new THREE.Mesh(this.geo, terrainMat);
    this.trees = new THREE.InstancedMesh(treeGeo, treeMat, TREES);
    scene.add(this.mesh, this.trees);
  }

  place(wz) {
    this.wz = wz;
    const pos = this.geo.attributes.position;
    const colors = this.geo.attributes.color;
    for (let i = 0; i < pos.count; i++) {
      const x = this.base[i * 3], z = this.base[i * 3 + 2] + wz;
      const h = height(x, z);
      const slope = Math.hypot(height(x + 30, z) - h, height(x, z + 30) - h) / 30;
      pos.setY(i, h);
      groundColor(h, slope, hash2(Math.round(x), Math.round(z)), col);
      colors.setXYZ(i, col.r, col.g, col.b);
    }
    pos.needsUpdate = colors.needsUpdate = true;
    this.geo.computeVertexNormals();
    this.geo.computeBoundingSphere();

    const rand = rng(Math.round(wz / CHUNK_D) * 7919 + 13);
    for (let i = 0; i < TREES; i++) {
      const x = (rand() - 0.5) * 5000, z = (rand() - 0.5) * CHUNK_D;
      const h = height(x, z + wz);
      const slope = Math.abs(height(x + 20, z + wz) - h) / 20;
      if (h < 4 || h > 700 || slope > 0.6) {
        this.trees.setMatrixAt(i, HIDE);
        continue;
      }
      const s = 0.7 + rand() * 0.9;
      mat4.makeScale(s, s * (0.8 + rand() * 0.5), s).setPosition(x, h - 1, z);
      this.trees.setMatrixAt(i, mat4);
    }
    this.trees.instanceMatrix.needsUpdate = true;
    this.trees.computeBoundingSphere();
  }

  update() {
    this.mesh.position.z = this.trees.position.z = this.wz + travelled;
  }
}

const chunks = [];
for (let i = 0; i < NCHUNKS; i++) {
  const c = new Chunk();
  c.place(CHUNK_D * (1 - i));
  chunks.push(c);
}

const water = new THREE.Mesh(
  new THREE.PlaneGeometry(40000, 40000).rotateX(-Math.PI / 2),
  new THREE.MeshPhongMaterial({ color: 0x2c6587, specular: 0x9fc6e0, shininess: 60 }),
);
scene.add(water);

const CLOUDS = 60, PUFFS = 7;
const cloudMesh = new THREE.InstancedMesh(
  new THREE.IcosahedronGeometry(1, 1),
  new THREE.MeshLambertMaterial({ color: 0xffffff, emissive: 0x8a96a6, flatShading: true }),
  CLOUDS * PUFFS,
);
cloudMesh.frustumCulled = false;
scene.add(cloudMesh);

const cloudRand = rng(42);
const clouds = [];

function spawnCloud(c, wz) {
  c.x = (cloudRand() - 0.5) * 12000;
  c.y = 700 + cloudRand() * 1100;
  if (Math.abs(c.x) < 400 && Math.abs(c.y - ALT) < 250) c.x += 900 * Math.sign(c.x || 1);
  c.wz = wz;
  const size = 60 + cloudRand() * 110;
  c.puffs = [];
  for (let i = 0; i < PUFFS; i++) {
    c.puffs.push([
      (cloudRand() - 0.5) * size * 3.2,
      (cloudRand() - 0.3) * size * 0.6,
      (cloudRand() - 0.5) * size * 1.8,
      size * (0.5 + cloudRand() * 0.6),
    ]);
  }
}
for (let i = 0; i < CLOUDS; i++) {
  const c = {};
  spawnCloud(c, 2500 - cloudRand() * 15000);
  clouds.push(c);
}

const balloonRand = rng(7);
const BALLOON_COLORS = [[0xe63946, 0xf1faee], [0xffb703, 0x219ebc], [0x8338ec, 0xffbe0b], [0x2a9d8f, 0xe9c46a], [0xef476f, 0x073b4c]];
const balloons = [];

function makeBalloon() {
  const [a, b] = BALLOON_COLORS[Math.floor(balloonRand() * BALLOON_COLORS.length)];
  const ca = new THREE.Color(a), cb = new THREE.Color(b);
  const geo = new THREE.SphereGeometry(11, 16, 12);
  const p = geo.attributes.position;
  const colors = new Float32Array(p.count * 3);
  for (let i = 0; i < p.count; i++) {
    const ang = Math.atan2(p.getZ(i), p.getX(i));
    const c = Math.floor((ang + Math.PI) / (Math.PI / 4)) % 2 ? ca : cb;
    colors.set([c.r, c.g, c.b], i * 3);
  }
  geo.setAttribute('color', new THREE.BufferAttribute(colors, 3));
  geo.scale(1, 1.2, 1);

  const g = new THREE.Group();
  g.add(new THREE.Mesh(geo, new THREE.MeshLambertMaterial({ vertexColors: true, flatShading: true })));
  const basket = new THREE.Mesh(new THREE.BoxGeometry(3, 2.4, 3), new THREE.MeshLambertMaterial({ color: 0x7a5530 }));
  basket.position.y = -19;
  g.add(basket);
  const pts = [];
  for (const [x, z] of [[-1, -1], [1, -1], [-1, 1], [1, 1]]) {
    pts.push(new THREE.Vector3(x * 1.4, -18, z * 1.4), new THREE.Vector3(x * 6, -9, z * 6));
  }
  g.add(new THREE.LineSegments(new THREE.BufferGeometry().setFromPoints(pts), new THREE.LineBasicMaterial({ color: 0x333333 })));
  scene.add(g);
  return { g, x: 0, y: 0, wz: 0, phase: balloonRand() * 6 };
}

function spawnBalloon(b, wz) {
  b.x = (balloonRand() < 0.5 ? -1 : 1) * (160 + balloonRand() * 1300);
  b.y = ALT - 140 + balloonRand() * 420;
  b.wz = wz;
}

for (let i = 0; i < 12; i++) {
  const b = makeBalloon();
  spawnBalloon(b, 1500 - i * 900 - balloonRand() * 400);
  balloons.push(b);
}

const ac = new THREE.Group();
ac.position.set(0, ALT, 0);
scene.add(ac);

const paint = new THREE.MeshLambertMaterial({ color: 0xe4e7ec });
const red = new THREE.MeshLambertMaterial({ color: 0xc62f2f });
const interior = new THREE.MeshLambertMaterial({ color: 0x2b3038 });
const frameMat = new THREE.MeshLambertMaterial({ color: 0x3b414a });
const panelMat = new THREE.MeshLambertMaterial({ color: 0x1b1f24 });
const black = new THREE.MeshLambertMaterial({ color: 0x111111 });

function box(w, h, d, mat, x, y, z, parent = ac) {
  const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), mat);
  m.position.set(x, y, z);
  parent.add(m);
  return m;
}

box(1.0, 0.75, 6.4, paint, 0, -0.98, 0.6);
box(0.92, 0.14, 2.2, paint, 0, -0.33, -2.0);
box(0.5, 0.02, 2.2, black, 0, -0.255, -2.0);
box(0.9, 0.35, 4.2, paint, 0, -0.55, 3.0);
box(0.08, 1.5, 1.3, paint, 0, 0.15, 6.6);
box(0.1, 0.2, 1.3, red, 0, 0.8, 6.6);
box(3.6, 0.06, 0.95, paint, 0, -0.5, 6.7);

const nose = new THREE.Mesh(new THREE.CylinderGeometry(0.28, 0.55, 1.3, 16), paint);
nose.rotation.x = -Math.PI / 2;
nose.position.set(0, -0.6, -3.7);
ac.add(nose);
const spinner = new THREE.Mesh(new THREE.ConeGeometry(0.2, 0.45, 16), red);
spinner.rotation.x = -Math.PI / 2;
spinner.position.set(0, -0.6, -4.55);
ac.add(spinner);

const propDisc = new THREE.Mesh(
  new THREE.CircleGeometry(1.05, 40),
  new THREE.MeshBasicMaterial({ color: 0x222222, transparent: true, opacity: 0.13, side: THREE.DoubleSide, depthWrite: false }),
);
propDisc.position.set(0, -0.6, -4.42);
ac.add(propDisc);
const prop = box(0.09, 2.0, 0.02, black, 0, -0.6, -4.44);

box(11.6, 0.13, 1.8, paint, 0, -1.15, 0.3);
box(11.6, 0.135, 0.25, red, 0, -1.15, -0.45);
for (const [x, c] of [[-5.85, 0xff2a2a], [5.85, 0x2aff5a]]) {
  const light = new THREE.Mesh(new THREE.SphereGeometry(0.12, 12, 8), new THREE.MeshBasicMaterial({ color: c }));
  light.position.set(x, -1.12, 0.1);
  ac.add(light);
}

box(0.08, 0.5, 1.9, interior, -0.66, -0.47, -0.3);
box(0.08, 0.5, 1.9, interior, 0.66, -0.47, -0.3);
box(0.22, 0.12, 0.85, frameMat, -0.5, -0.56, -0.05);
box(0.22, 0.12, 0.85, frameMat, 0.5, -0.56, -0.05);
box(1.25, 0.42, 0.06, panelMat, 0, -0.41, -0.79);
box(1.32, 0.05, 0.34, interior, 0, -0.18, -0.88);
box(0.5, 0.72, 0.1, interior, 0, -0.5, 0.52);
box(0.36, 0.3, 0.12, interior, 0, -0.04, 0.47);
box(1.24, 0.04, 2.1, panelMat, 0, -0.62, -0.25);
box(0.5, 0.1, 0.5, interior, 0, -0.62, 0.25);
for (const x of [-0.17, 0.17]) {
  box(0.13, 0.12, 0.75, frameMat, x, -0.56, -0.15).rotation.x = -0.12;
  box(0.1, 0.16, 0.03, black, x, -0.55, -0.62);
}

const stick = new THREE.Mesh(new THREE.CylinderGeometry(0.015, 0.022, 0.42, 8), black);
stick.position.set(0, -0.78, -0.42);
ac.add(stick);
const grip = new THREE.Mesh(new THREE.CylinderGeometry(0.03, 0.03, 0.12, 10), black);
grip.position.set(0, -0.52, -0.42);
ac.add(grip);

for (const [z, rake] of [[-0.98, -0.55], [0.3, 0.08]]) {
  const bow = new THREE.Mesh(new THREE.TorusGeometry(0.64, 0.022, 8, 40, Math.PI), frameMat);
  bow.position.set(0, -0.22, z);
  bow.rotation.x = rake;
  ac.add(bow);
}
box(0.05, 0.05, 1.5, frameMat, -0.64, -0.22, -0.35);
box(0.05, 0.05, 1.5, frameMat, 0.64, -0.22, -0.35);

const glass = new THREE.Mesh(
  new THREE.SphereGeometry(0.66, 32, 16, 0, Math.PI * 2, 0, Math.PI / 2),
  new THREE.MeshPhongMaterial({ color: 0x9fc4dd, transparent: true, opacity: 0.06, shininess: 120, side: THREE.DoubleSide, depthWrite: false }),
);
glass.scale.set(1, 1.05, 2.0);
glass.position.set(0, -0.22, -0.35);
ac.add(glass);

const PW = 1024, PH = 344;
const panelCanvas = document.createElement('canvas');
panelCanvas.width = PW * 2;
panelCanvas.height = PH * 2;
const pc = panelCanvas.getContext('2d');
const panelTex = new THREE.CanvasTexture(panelCanvas);
panelTex.anisotropy = 8;
const panelFace = new THREE.Mesh(new THREE.PlaneGeometry(1.2, 0.4), new THREE.MeshBasicMaterial({ map: panelTex }));
panelFace.position.set(0, -0.41, -0.755);
ac.add(panelFace);

function makePlane(color) {
  const g = new THREE.Group();
  const m = new THREE.MeshLambertMaterial({ color });
  box(1.0, 1.0, 7.5, m, 0, 0, 0, g);
  box(11, 0.14, 1.8, m, 0, -0.35, -0.6, g);
  box(3.6, 0.08, 0.9, m, 0, 0.1, 3.4, g);
  box(0.1, 1.4, 1.1, m, 0, 0.7, 3.4, g);
  box(0.75, 0.45, 1.6, new THREE.MeshPhongMaterial({ color: 0x223344, shininess: 90 }), 0, 0.6, -0.9, g);
  const n = new THREE.Mesh(new THREE.ConeGeometry(0.5, 1.2, 12), m);
  n.rotation.x = -Math.PI / 2;
  n.position.z = -4.3;
  g.add(n);
  scene.add(g);
  return g;
}

const wingmen = [
  { g: makePlane(0xf2c14e), x: 36, y: -5, z: -16, ph: 0 },
  { g: makePlane(0x4ea8de), x: -52, y: 7, z: 22, ph: 2.1 },
];

const neck = new THREE.Object3D();
neck.position.set(0, -0.12, 0.09);
ac.add(neck);
neck.add(camera);
camera.position.set(0, 0.12, -0.09);

function bezel(x, y, r) {
  pc.fillStyle = '#111';
  pc.beginPath(); pc.arc(x, y, r + 6, 0, 7); pc.fill();
  pc.fillStyle = '#060606';
  pc.beginPath(); pc.arc(x, y, r, 0, 7); pc.fill();
}

function ticks(x, y, r, a0, a1, n, len, width = 1.5) {
  pc.strokeStyle = '#e8e8e8';
  pc.lineWidth = width;
  pc.beginPath();
  for (let i = 0; i <= n; i++) {
    const a = a0 + ((a1 - a0) * i) / n;
    pc.moveTo(x + Math.cos(a) * r, y + Math.sin(a) * r);
    pc.lineTo(x + Math.cos(a) * (r - len), y + Math.sin(a) * (r - len));
  }
  pc.stroke();
}

function band(x, y, r, a0, a1, color, width) {
  pc.strokeStyle = color;
  pc.lineWidth = width;
  pc.beginPath(); pc.arc(x, y, r, a0, a1); pc.stroke();
}

function needle(x, y, a, len, width = 4) {
  pc.save();
  pc.translate(x, y);
  pc.rotate(a);
  pc.fillStyle = '#f4f4f4';
  pc.beginPath();
  pc.moveTo(-len * 0.18, -width / 2);
  pc.lineTo(len - 8, -width / 2);
  pc.lineTo(len, 0);
  pc.lineTo(len - 8, width / 2);
  pc.lineTo(-len * 0.18, width / 2);
  pc.fill();
  pc.restore();
  pc.fillStyle = '#222';
  pc.beginPath(); pc.arc(x, y, 5, 0, 7); pc.fill();
}

function text(s, x, y, size = 11, color = '#ddd', font = 'Helvetica, Arial, sans-serif') {
  pc.fillStyle = color;
  pc.font = `${size}px ${font}`;
  pc.textAlign = 'center';
  pc.textBaseline = 'middle';
  pc.fillText(s, x, y);
}

function airspeed(x, y, r, kt) {
  const A = (v) => -Math.PI / 2 + (v / 200) * Math.PI * 1.8;
  bezel(x, y, r);
  band(x, y, r - 13, A(40), A(85), '#eee', 4);
  band(x, y, r - 5, A(50), A(130), '#2b9a3a', 7);
  band(x, y, r - 5, A(130), A(165), '#d8c02a', 7);
  pc.strokeStyle = '#d33'; pc.lineWidth = 4;
  pc.beginPath(); pc.moveTo(x + Math.cos(A(165)) * (r - 2), y + Math.sin(A(165)) * (r - 2));
  pc.lineTo(x + Math.cos(A(165)) * (r - 16), y + Math.sin(A(165)) * (r - 16)); pc.stroke();
  ticks(x, y, r - 2, A(40), A(200), 32, 6);
  ticks(x, y, r - 2, A(40), A(200), 8, 11, 2);
  for (let v = 40; v <= 200; v += 20) text(v, x + Math.cos(A(v)) * (r - 26), y + Math.sin(A(v)) * (r - 26), 12);
  text('AIRSPEED', x, y + r * 0.3, 8, '#bbb');
  text('KNOTS', x, y + r * 0.45, 8, '#bbb');
  needle(x, y, A(kt), r - 10);
}

function attitude(x, y, r, pitch, roll) {
  bezel(x, y, r);
  pc.save();
  pc.translate(x, y);
  pc.beginPath(); pc.arc(0, 0, r, 0, 7); pc.clip();
  pc.rotate(-roll * D2R);
  const k = r / 30;
  const off = pitch * k;
  pc.fillStyle = '#2f6db5'; pc.fillRect(-r * 2, -r * 3 + off, r * 4, r * 3);
  pc.fillStyle = '#7a4b25'; pc.fillRect(-r * 2, off, r * 4, r * 3);
  pc.strokeStyle = '#fff';
  pc.lineWidth = 2;
  pc.beginPath(); pc.moveTo(-r, off); pc.lineTo(r, off);
  for (const p of [-10, -5, 5, 10]) {
    const w = Math.abs(p) === 10 ? r * 0.3 : r * 0.15;
    pc.moveTo(-w, off - p * k); pc.lineTo(w, off - p * k);
  }
  pc.stroke();
  pc.lineWidth = 2;
  pc.beginPath();
  for (const b of [-60, -30, -20, -10, 10, 20, 30, 60]) {
    const a = (-90 + b) * D2R, len = Math.abs(b) % 30 === 0 ? 12 : 7;
    pc.moveTo(Math.cos(a) * r, Math.sin(a) * r);
    pc.lineTo(Math.cos(a) * (r - len), Math.sin(a) * (r - len));
  }
  pc.stroke();
  pc.fillStyle = '#fff';
  pc.beginPath(); pc.moveTo(0, -r + 12); pc.lineTo(-5, -r + 2); pc.lineTo(5, -r + 2); pc.fill();
  pc.restore();

  pc.strokeStyle = '#f39c1d';
  pc.lineWidth = 4;
  pc.beginPath();
  pc.moveTo(x - r * 0.55, y); pc.lineTo(x - r * 0.18, y); pc.lineTo(x, y + r * 0.1); pc.lineTo(x + r * 0.18, y); pc.lineTo(x + r * 0.55, y);
  pc.stroke();
  pc.fillStyle = '#f39c1d';
  pc.beginPath(); pc.arc(x, y, 3, 0, 7); pc.fill();
}

function altimeter(x, y, r, ft) {
  const A = (f) => -Math.PI / 2 + f * Math.PI * 2;
  bezel(x, y, r);
  ticks(x, y, r - 2, A(0), A(1), 50, 6);
  ticks(x, y, r - 2, A(0), A(1), 10, 12, 2.5);
  for (let i = 0; i < 10; i++) text(i, x + Math.cos(A(i / 10)) * (r - 25), y + Math.sin(A(i / 10)) * (r - 25), 15);
  pc.fillStyle = '#000';
  pc.fillRect(x + r * 0.22, y - 8, 38, 16);
  text('29.92', x + r * 0.22 + 19, y, 10, '#eee', 'Menlo, monospace');
  text('ALT', x, y - r * 0.35, 9, '#bbb');
  text('100 FEET', x, y + r * 0.42, 8, '#bbb');
  needle(x, y, A((ft % 10000) / 10000), r * 0.5, 8);
  needle(x, y, A((ft % 1000) / 1000), r - 10, 4);
}

function turnCoordinator(x, y, r, bank, slip) {
  bezel(x, y, r);
  for (const s of [-1, 1]) {
    for (const a of [0, 15]) {
      const ang = (s < 0 ? 180 : 0) + s * a;
      const rad = ang * D2R;
      pc.strokeStyle = '#eee'; pc.lineWidth = 3;
      pc.beginPath();
      pc.moveTo(x + Math.cos(rad) * (r - 4), y + Math.sin(rad) * (r - 4));
      pc.lineTo(x + Math.cos(rad) * (r - 16), y + Math.sin(rad) * (r - 16));
      pc.stroke();
    }
  }
  text('L', x - r * 0.72, y + r * 0.42, 13);
  text('R', x + r * 0.72, y + r * 0.42, 13);
  text('2 MIN', x, y + r * 0.72, 8, '#bbb');
  text('TURN COORDINATOR', x, y - r * 0.5, 7, '#bbb');

  pc.save();
  pc.translate(x, y);
  pc.rotate(-bank * D2R * 2);
  pc.strokeStyle = '#fff'; pc.lineWidth = 4;
  pc.beginPath(); pc.moveTo(-r * 0.7, 0); pc.lineTo(r * 0.7, 0); pc.moveTo(0, -12); pc.lineTo(0, 0); pc.stroke();
  pc.fillStyle = '#fff';
  pc.beginPath(); pc.arc(0, 0, 7, 0, 7); pc.fill();
  pc.restore();

  const by = y + r * 0.42;
  pc.fillStyle = '#c9d2c2';
  pc.fillRect(x - r * 0.42, by - 8, r * 0.84, 16);
  pc.strokeStyle = '#111'; pc.lineWidth = 2;
  pc.beginPath(); pc.moveTo(x - 9, by - 8); pc.lineTo(x - 9, by + 8); pc.moveTo(x + 9, by - 8); pc.lineTo(x + 9, by + 8); pc.stroke();
  pc.fillStyle = '#111';
  pc.beginPath(); pc.arc(x + slip, by, 7, 0, 7); pc.fill();
}

function headingIndicator(x, y, r, hdg) {
  bezel(x, y, r);
  pc.save();
  pc.translate(x, y);
  pc.rotate(-hdg * D2R);
  pc.strokeStyle = '#eee'; pc.lineWidth = 1.5;
  pc.beginPath();
  for (let d = 0; d < 360; d += 5) {
    const a = (d - 90) * D2R, len = d % 10 ? 6 : 11;
    pc.moveTo(Math.cos(a) * (r - 2), Math.sin(a) * (r - 2));
    pc.lineTo(Math.cos(a) * (r - 2 - len), Math.sin(a) * (r - 2 - len));
  }
  pc.stroke();
  const names = { 0: 'N', 90: 'E', 180: 'S', 270: 'W' };
  for (let d = 0; d < 360; d += 30) {
    pc.save();
    pc.rotate(d * D2R);
    text(names[d] || d / 10, 0, -r + 26, names[d] ? 15 : 13);
    pc.restore();
  }
  pc.restore();
  pc.fillStyle = '#f39c1d';
  pc.beginPath(); pc.moveTo(x, y - r + 14); pc.lineTo(x - 5, y - r + 2); pc.lineTo(x + 5, y - r + 2); pc.fill();
  pc.strokeStyle = '#f39c1d'; pc.lineWidth = 3;
  pc.beginPath();
  pc.moveTo(x, y - 20); pc.lineTo(x, y + 18);
  pc.moveTo(x - 16, y - 2); pc.lineTo(x + 16, y - 2);
  pc.moveTo(x - 7, y + 15); pc.lineTo(x + 7, y + 15);
  pc.stroke();
}

function vsi(x, y, r, fpm) {
  const A = (v) => Math.PI + (Math.max(-2000, Math.min(2000, v)) / 2000) * Math.PI * 0.94;
  bezel(x, y, r);
  ticks(x, y, r - 2, A(-2000), A(2000), 40, 6);
  ticks(x, y, r - 2, A(-2000), A(2000), 8, 12, 2.5);
  text('0', x - r + 24, y, 14);
  for (const v of [500, 1000, 1500, 2000]) {
    for (const s of [-1, 1]) {
      const a = A(v * s);
      text(v / 100, x + Math.cos(a) * (r - 26), y + Math.sin(a) * (r - 26), 13);
    }
  }
  text('UP', x - r * 0.35, y - r * 0.25, 8, '#bbb');
  text('DOWN', x - r * 0.35, y + r * 0.25, 8, '#bbb');
  text('VERT SPEED', x + r * 0.3, y - 8, 7, '#bbb');
  text('100 FPM', x + r * 0.3, y + 8, 7, '#bbb');
  needle(x, y, A(fpm), r - 10);
}

function tach(x, y, r, rpm) {
  const A = (v) => (135 + (v / 3500) * 270) * D2R;
  bezel(x, y, r);
  band(x, y, r - 6, A(2100), A(2700), '#2b9a3a', 8);
  pc.strokeStyle = '#d33'; pc.lineWidth = 4;
  pc.beginPath(); pc.moveTo(x + Math.cos(A(2700)) * (r - 2), y + Math.sin(A(2700)) * (r - 2));
  pc.lineTo(x + Math.cos(A(2700)) * (r - 18), y + Math.sin(A(2700)) * (r - 18)); pc.stroke();
  ticks(x, y, r - 2, A(0), A(3500), 35, 6);
  ticks(x, y, r - 2, A(0), A(3500), 7, 12, 2.5);
  for (let v = 0; v <= 3500; v += 500) text(v / 100, x + Math.cos(A(v)) * (r - 26), y + Math.sin(A(v)) * (r - 26), 13);
  text('RPM', x, y + r * 0.32, 9, '#bbb');
  text('x100', x, y + r * 0.46, 8, '#bbb');
  needle(x, y, A(rpm), r - 10);
}

function radio(x, y, w, h, name, a, b) {
  pc.fillStyle = '#26292d';
  pc.fillRect(x, y, w, h);
  pc.fillStyle = '#000';
  pc.fillRect(x + 8, y + 8, w - 16, h - 16);
  text(name, x + 30, y + h / 2, 10, '#999', 'Menlo, monospace');
  text(a, x + 92, y + h / 2, 15, '#ffb000', 'Menlo, monospace');
  text(b, x + 160, y + h / 2, 15, '#7d5a14', 'Menlo, monospace');
}

let lastAlt = ALT * 3.281, vs = 0;

function drawPanel(dt, t) {
  pc.setTransform(2, 0, 0, 2, 0, 0);
  pc.fillStyle = '#2a2d31';
  pc.fillRect(0, 0, PW, PH);

  const alt = ac.position.y * 3.281;
  vs += ((alt - lastAlt) / dt * 60 - vs) * 0.2;
  lastAlt = alt;

  const r = 72;
  tach(160, 172, r, 2380 + Math.sin(t * 1.7) * 8);
  airspeed(340, 90, r, SPEED * 1.944 + Math.sin(t * 0.9) * 0.6);
  attitude(512, 90, r, ac.rotation.x / D2R, ac.rotation.z / D2R);
  altimeter(684, 90, r, alt);
  turnCoordinator(340, 254, r, ac.rotation.z / D2R, Math.sin(t * 0.4) * 1.5);
  headingIndicator(512, 254, r, 0);
  vsi(684, 254, r, vs);

  radio(800, 50, 210, 50, 'COM1', '122.80', '121.50');
  radio(800, 110, 210, 50, 'NAV1', '110.50', '113.90');
  radio(800, 170, 210, 50, 'XPDR', '1200', 'ALT');

  panelTex.needsUpdate = true;
}

const info = document.getElementById('info');
const promptEl = document.getElementById('prompt');
const msgEl = document.getElementById('msg');

let msgTimer;
function message(s, ms = 4000) {
  msgEl.textContent = s;
  clearTimeout(msgTimer);
  if (ms) msgTimer = setTimeout(() => (msgEl.textContent = ''), ms);
}

function showPrompt(html) {
  promptEl.innerHTML = html;
}

const pad = (v) => (v >= 0 ? '+' : '') + v.toFixed(1);

function updateInfo(yaw, pitch, roll) {
  let line;
  if (!bridgeUp) line = '<span class="bad">bridge offline</span> <span class="dim">(open the Kopfkino app)</span>';
  else if (status && (status.auth === 'denied' || status.auth === 'restricted')) line = '<span class="bad">motion permission denied</span>';
  else if (status && !status.available) line = '<span class="bad">headphone motion unavailable (needs macOS 14)</span>';
  else if (isLive()) line = `<span class="ok">tracking ${hz} Hz</span> <span class="dim">${sensor}</span>`;
  else line = '<span class="warn">no airpods data</span> <span class="dim">(mouse look)</span>';

  const mode = cfg ? cfg.mode : 'pov';
  const modeName = { off: 'OFF', pov: 'POV', cursor: 'CURSOR' }[mode];
  let s = `kopfkino  ${line}  <span class="${mode === 'off' ? 'dim' : 'ok'}">[${modeName}]</span>\n`;
  s += `yaw ${pad(yaw).padStart(7)}  pitch ${pad(pitch).padStart(6)}  roll ${pad(roll).padStart(6)}\n`;
  if (cfg && !cfg.calibrated && isLive()) s += '<span class="warn">not calibrated, press k</span>\n';
  if (mode !== 'off' && status && status.mouseAccess === false) s += '<span class="warn">mouse control needs Accessibility (menu bar > Allow Mouse Control)</span>\n';
  if (mode === 'cursor') s += '<span class="dim">cursor mode: sim view is parked, nod to click</span>\n';
  if (mode === 'pov' && status) s += status.captured ? '<span class="ok">pov: game has the mouse, head look on</span>\n' : '<span class="dim">pov: games get head look when they capture the mouse</span>\n';
  s += '<span class="dim">space recenter  k calibrate  s settings  h hide\nopt+shift+k on/off  opt+shift+m pov/cursor  opt+shift+r recenter  opt+shift+c calibrate</span>';
  info.innerHTML = s;
}

const settings = {
  yawGain: 2,
  pitchGain: 1.6,
  rollGain: 1,
  deadzone: 0.4,
  useRoll: true,
  response,
  fov,
  opentrack: true,
  mode: 'pov',
  povSpeed: 7,
  cursorReach: 15,
  nodClick: true,
  curve: 0.5,
  spatialAudio: false,
  recenter,
  calibrate: () => calibrate(),
  reset: () => post('/api/config/reset').catch(() => {}),
};

function flip(axis) {
  if (!cfg) return;
  post('/api/config', { [axis]: { source: cfg[axis].source, sign: -cfg[axis].sign } }).catch(() => {});
}

const gui = new GUI({ title: 'Kopfkino' });
gui.add(settings, 'mode', { off: 'off', POV: 'pov', cursor: 'cursor' }).name('mode').onChange((v) => setConfig({ mode: v }));
const tr = gui.addFolder('Tracking');
tr.add(settings, 'yawGain', 0.5, 5, 0.1).name('yaw gain').onChange((v) => setConfig({ gainYaw: v }));
tr.add(settings, 'pitchGain', 0.5, 5, 0.1).name('pitch gain').onChange((v) => setConfig({ gainPitch: v }));
tr.add(settings, 'rollGain', 0, 3, 0.1).name('roll gain').onChange((v) => setConfig({ gainRoll: v }));
tr.add(settings, 'curve', 0, 1, 0.05).name('response curve').onChange((v) => setConfig({ curve: v }));
tr.add(settings, 'deadzone', 0, 5, 0.1).name('deadzone (deg)').onChange((v) => setConfig({ deadzoneDeg: v }));
tr.add(settings, 'useRoll').name('use roll').onChange((v) => setConfig({ enableRoll: v }));
tr.add({ f: () => flip('yaw') }, 'f').name('flip yaw');
tr.add({ f: () => flip('pitch') }, 'f').name('flip pitch');
tr.add({ f: () => flip('roll') }, 'f').name('flip roll');

const vf = gui.addFolder('View');
vf.add(settings, 'response', 4, 60, 1).name('response').onChange((v) => { response = v; save('response', v); });
vf.add(settings, 'fov', 50, 110, 1).name('fov').onChange((v) => {
  fov = v;
  save('fov', v);
  camera.fov = v;
  camera.updateProjectionMatrix();
});

const of = gui.addFolder('Output');
of.add(settings, 'povSpeed', 1, 40, 0.5).name('pov mouse speed').onChange((v) => setConfig({ povMouseSpeed: v }));
of.add(settings, 'cursorReach', 5, 45, 1).name('cursor reach (deg)').onChange((v) => setConfig({ cursorReachX: v, cursorReachY: Math.round(v * 0.6) }));
of.add(settings, 'spatialAudio').name('spatial audio² (all apps)').onChange((v) => setConfig({ spatialAudio: v }));
of.add(settings, 'nodClick').name('nod to click').onChange((v) => setConfig({ nodClick: v }));
of.add(settings, 'opentrack').name('opentrack udp :4242').onChange((v) => setConfig({ opentrackEnabled: v }));

gui.add(settings, 'recenter');
gui.add(settings, 'calibrate');
gui.add(settings, 'reset').name('reset defaults');
gui.close();

function onConfig(c) {
  cfg = c;
  settings.yawGain = c.gainYaw;
  settings.pitchGain = c.gainPitch;
  settings.rollGain = c.gainRoll;
  settings.deadzone = c.deadzoneDeg;
  settings.useRoll = c.enableRoll;
  settings.opentrack = c.opentrackEnabled;
  settings.mode = c.mode;
  settings.povSpeed = c.povMouseSpeed;
  settings.cursorReach = c.cursorReachX;
  settings.nodClick = c.nodClick;
  settings.curve = c.curve;
  settings.spatialAudio = c.spatialAudio;
  gui.controllersRecursive().forEach((ctl) => ctl.updateDisplay());
}

let calibTimer;

function calibrate() {
  post('/api/calibrate', { action: 'toggle' }).catch(() => message('calibration needs the Kopfkino app running'));
}

function onCalib(c) {
  clearTimeout(calibTimer);
  if (c.state === 'running') {
    const left = Math.max(0, Math.ceil(c.remaining));
    showPrompt(`CALIBRATION ${c.step}/${c.total}<br>${c.title.toUpperCase()}<small>${c.sub} &nbsp; ${left}</small>`);
  } else if (c.state === 'done') {
    showPrompt('CALIBRATED<small>saved for good. run it again any time with k or opt+shift+c</small>');
    calibTimer = setTimeout(() => showPrompt(''), 3500);
  } else if (c.state === 'failed') {
    showPrompt(`CALIBRATION FAILED<small>${c.message}. press k to try again</small>`);
    calibTimer = setTimeout(() => showPrompt(''), 6000);
  } else {
    showPrompt('');
  }
}

let guiOpen = false;

addEventListener('keydown', (e) => {
  if (e.target.tagName === 'INPUT' || e.metaKey || e.ctrlKey) return;
  const k = e.key.toLowerCase();
  if (k === ' ' || k === 'c') {
    e.preventDefault();
    recenter();
  } else if (k === 'k') {
    calibrate();
  } else if (k === 's') {
    guiOpen = !guiOpen;
    guiOpen ? gui.open() : gui.close();
  } else if (k === 'h') {
    showUI = !showUI;
    info.classList.toggle('hidden', !showUI);
    gui.show(showUI);
  } else if (k === 'f') {
    if (document.fullscreenElement) document.exitFullscreen();
    else document.documentElement.requestFullscreen().catch(() => {});
  } else if (k === 'p') {
    flying = !flying;
    message(flying ? 'resumed' : 'paused', 1200);
  } else if (k === 'escape') {
    post('/api/calibrate', { action: 'cancel' }).catch(() => {});
  }
});

const canvas = renderer.domElement;
canvas.addEventListener('pointerdown', (e) => {
  mouse.down = true;
  mouse.x = e.clientX;
  mouse.y = e.clientY;
  canvas.setPointerCapture(e.pointerId);
});
canvas.addEventListener('pointermove', (e) => {
  if (!mouse.down) return;
  mouse.yaw = Math.max(-180, Math.min(180, mouse.yaw + (e.clientX - mouse.x) * 0.25));
  mouse.pitch = Math.max(-85, Math.min(85, mouse.pitch + (e.clientY - mouse.y) * 0.25));
  mouse.x = e.clientX;
  mouse.y = e.clientY;
});
canvas.addEventListener('pointerup', () => (mouse.down = false));
canvas.addEventListener('dblclick', () => (mouse.yaw = mouse.pitch = 0));

addEventListener('resize', () => {
  camera.aspect = innerWidth / innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(innerWidth, innerHeight);
});

const target = new THREE.Quaternion();
const euler = new THREE.Euler(0, 0, 0, 'YXZ');
const clock = new THREE.Clock();
let t = 0, panelT = 1, infoT = 1;

function tick() {
  requestAnimationFrame(tick);
  const dt = Math.min(0.05, clock.getDelta());
  t += dt;
  if (flying) travelled += SPEED * dt;

  const live = isLive();
  const follow = live && (!cfg || cfg.mode === 'pov');
  const yaw = follow ? head.yaw : live ? 0 : -mouse.yaw;
  const pitch = follow ? head.pitch : live ? 0 : -mouse.pitch;
  const roll = follow ? head.roll : 0;

  target.setFromEuler(euler.set(pitch * D2R, yaw * D2R, roll * D2R));
  neck.quaternion.slerp(target, 1 - Math.exp(-response * dt));

  ac.position.y = ALT + Math.sin(t * 0.7) * 0.5;
  ac.rotation.z = Math.sin(t * 0.37) * 0.01;
  ac.rotation.x = Math.sin(t * 0.53) * 0.006;
  propDisc.rotation.z += dt * 40;
  prop.rotation.z += dt * 47;

  for (const c of chunks) {
    if (c.wz + travelled > CHUNK_D * 1.5) c.place(c.wz - NCHUNKS * CHUNK_D);
    c.update();
  }

  let n = 0;
  for (const c of clouds) {
    if (c.wz + travelled > 4000) spawnCloud(c, -travelled - 12000 - cloudRand() * 3000);
    const z = c.wz + travelled;
    for (const [px, py, pz, s] of c.puffs) {
      mat4.makeScale(s, s * 0.62, s).setPosition(c.x + px, c.y + py, z + pz);
      cloudMesh.setMatrixAt(n++, mat4);
    }
  }
  cloudMesh.instanceMatrix.needsUpdate = true;

  for (const b of balloons) {
    if (b.wz + travelled > 1500) spawnBalloon(b, -travelled - 9000 - balloonRand() * 2500);
    b.g.position.set(b.x, b.y + Math.sin(t * 0.3 + b.phase) * 4, b.wz + travelled);
    b.g.rotation.y = t * 0.05 + b.phase;
  }

  for (const w of wingmen) {
    w.g.position.set(
      w.x + Math.sin(t * 0.31 + w.ph) * 2.5,
      ALT + w.y + Math.sin(t * 0.47 + w.ph) * 1.6,
      w.z + Math.sin(t * 0.23 + w.ph) * 3,
    );
    w.g.rotation.z = Math.sin(t * 0.31 + w.ph + 0.5) * 0.06;
  }

  panelT += dt;
  if (panelT > 0.05) {
    drawPanel(panelT, t);
    panelT = 0;
  }
  infoT += dt;
  if (infoT > 0.1 && showUI) {
    updateInfo(yaw, pitch, roll);
    infoT = 0;
  }

  renderer.render(scene, camera);
}

tick();

let hinted = false;
setInterval(() => {
  if (!hinted && isLive() && cfg) {
    hinted = true;
    if (!cfg.calibrated) message('tracking. press k to calibrate', 6000);
  }
}, 500);
