import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { VRMLoaderPlugin, VRMUtils } from '@pixiv/three-vrm';

const VRM_URL =
  'https://raw.githubusercontent.com/V-Sekai-fire/SK_VRM1_Constraint_Twist_Sample/main/' +
  'Constraint_Twist_Sample/Art/VRM1/VRM1_Constraint_Twist_Sample_01.vrm';

const canvas = document.getElementById('stage');
const boot = document.getElementById('vrm_boot');
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true });
renderer.setPixelRatio(window.devicePixelRatio);
renderer.outputColorSpace = THREE.SRGBColorSpace;

const scene = new THREE.Scene();
scene.background = new THREE.Color(0x0a0c0f);

const camera = new THREE.PerspectiveCamera(30, canvas.width / canvas.height, 0.1, 40);
scene.add(new THREE.HemisphereLight(0xffffff, 0x222233, 1.2));
const dir = new THREE.DirectionalLight(0xffffff, 1.6);
dir.position.set(2, 4, 3);
scene.add(dir);

// -- Avatar state (position + yaw) -----------------------------
const avatar = { pos: new THREE.Vector3(0, 0, 0), yaw: 0 };

// -- Camera orbit state ----------------------------------------
const orbit = { yaw: 0, pitch: -0.05, dist: 2.8, target: new THREE.Vector3(0, 1.15, 0) };

let vrm = null;
let poke = 0;

boot.textContent = '…fetching VRM…';
const loader = new GLTFLoader();
loader.register((parser) => new VRMLoaderPlugin(parser));
loader.load(
  VRM_URL,
  (gltf) => {
    vrm = gltf.userData.vrm;
    VRMUtils.removeUnnecessaryVertices(gltf.scene);
    VRMUtils.combineSkeletons(gltf.scene);
    VRMUtils.rotateVRM0(vrm);
    scene.add(vrm.scene);
    boot.innerHTML = `<span style="color:#00c8b3">ready.</span> three-vrm rendered ${vrm.meta?.name ?? 'avatar'}. WASD to move · click canvas + drag to look · gamepad L-stick moves R-stick looks.`;
  },
  (evt) => { if (evt.total) boot.textContent = `…VRM ${Math.round(100 * evt.loaded / evt.total)}%…`; },
  (err) => { boot.innerHTML = `<span style="color:#ff5aa2">VRM load failed:</span> ${err.message ?? err}`; },
);

// -- Keyboard --------------------------------------------------
const keys = new Set();
window.addEventListener('keydown', (e) => {
  if (['w','a','s','d','W','A','S','D','ArrowUp','ArrowDown','ArrowLeft','ArrowRight'].includes(e.key)) {
    keys.add(e.key.toLowerCase()); e.preventDefault();
  }
});
window.addEventListener('keyup', (e) => keys.delete(e.key.toLowerCase()));

// -- Mouse (pointer lock on canvas click) ----------------------
canvas.addEventListener('click', () => canvas.requestPointerLock?.());
window.addEventListener('mousemove', (e) => {
  if (document.pointerLockElement === canvas) {
    orbit.yaw   -= e.movementX * 0.003;
    orbit.pitch  = Math.max(-1.2, Math.min(0.6, orbit.pitch - e.movementY * 0.003));
  }
});
canvas.addEventListener('wheel', (e) => {
  orbit.dist = Math.max(1.2, Math.min(6, orbit.dist + e.deltaY * 0.003));
  e.preventDefault();
}, { passive: false });

// -- Gamepad ---------------------------------------------------
function readGamepad() {
  const pads = navigator.getGamepads?.() ?? [];
  for (const p of pads) if (p) return p;
  return null;
}
function deadzone(v, d = 0.15) { return Math.abs(v) < d ? 0 : v; }

// -- Frame loop ------------------------------------------------
const clock = new THREE.Clock();
function frame() {
  requestAnimationFrame(frame);
  const dt = clock.getDelta();

  // Movement input: WASD or gamepad L-stick.
  let mx = 0, mz = 0;
  if (keys.has('w') || keys.has('arrowup'))    mz -= 1;
  if (keys.has('s') || keys.has('arrowdown'))  mz += 1;
  if (keys.has('a') || keys.has('arrowleft'))  mx -= 1;
  if (keys.has('d') || keys.has('arrowright')) mx += 1;

  const pad = readGamepad();
  if (pad) {
    mx += deadzone(pad.axes[0] ?? 0);
    mz += deadzone(pad.axes[1] ?? 0);
    orbit.yaw   -= deadzone(pad.axes[2] ?? 0) * dt * 2.5;
    orbit.pitch  = Math.max(-1.2, Math.min(0.6, orbit.pitch - deadzone(pad.axes[3] ?? 0) * dt * 2.0));
  }

  // Move avatar in world XZ, aligned to camera yaw (so W is "forward relative to look").
  if (mx || mz) {
    const len = Math.hypot(mx, mz);
    const nx = mx / len, nz = mz / len;
    const cosY = Math.cos(orbit.yaw), sinY = Math.sin(orbit.yaw);
    const dx = (nx * cosY - nz * sinY) * dt * 2.0;
    const dz = (nx * sinY + nz * cosY) * dt * 2.0;
    avatar.pos.x += dx; avatar.pos.z += dz;
    avatar.yaw = Math.atan2(dx, dz) + Math.PI;
  }

  if (vrm) {
    vrm.scene.position.copy(avatar.pos);
    vrm.scene.rotation.y = avatar.yaw + poke;
    poke *= 0.9;
    vrm.update(dt);
  }

  // Camera orbit around the avatar.
  orbit.target.set(avatar.pos.x, avatar.pos.y + 1.15, avatar.pos.z);
  const cy = Math.cos(orbit.yaw), sy = Math.sin(orbit.yaw);
  const cp = Math.cos(orbit.pitch), sp = Math.sin(orbit.pitch);
  camera.position.set(
    orbit.target.x + sy * cp * orbit.dist,
    orbit.target.y + sp * orbit.dist * -1 + 0.2,
    orbit.target.z + cy * cp * orbit.dist,
  );
  camera.lookAt(orbit.target);

  renderer.render(scene, camera);
}
frame();

// Reflex hook — kept from the earlier commit: nudge yaw on each fire.
window.__vrm_reflex_cue = (_persona, _action) => { poke = 0.8; };
