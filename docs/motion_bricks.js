// Motion-bricks seam. Real impl is motion-bricks-cpp compiled to WASM
// (3-interactor/motion-bricks-cpp, C++23 + GGML, 730 MB GGUF weights).
// That's a multi-session build (emsdk + patched ggml WASM backend +
// weight-streaming design). Until it lands, this JS stub keys the same
// brick_ids onto direct three-vrm humanoid bone animations so the seam
// works end-to-end and the swap is single-file.

import { VRMHumanBoneName } from '@pixiv/three-vrm';

const bricks = {
  wave:      { bone: VRMHumanBoneName.RightUpperArm, axis: 'z', amp:  1.2, hz: 3.0, dur: 1.2 },
  bow:       { bone: VRMHumanBoneName.Spine,         axis: 'x', amp:  0.6, hz: 0.9, dur: 1.5, once: true },
  nod:       { bone: VRMHumanBoneName.Head,          axis: 'x', amp:  0.35, hz: 2.4, dur: 0.7 },
  shake:     { bone: VRMHumanBoneName.Head,          axis: 'y', amp:  0.35, hz: 2.4, dur: 0.7 },
  look_up:   { bone: VRMHumanBoneName.Head,          axis: 'x', amp: -0.5, hz: 0.6, dur: 1.2, once: true },
  point_road:{ bone: VRMHumanBoneName.RightUpperArm, axis: 'z', amp:  1.4, hz: 0.4, dur: 1.5, once: true },
};

const active = new Map();  // bone -> { startedAt, dur, axis, amp, hz, rest, once }

export function play(brick_id, vrm) {
  const spec = bricks[brick_id];
  if (!spec || !vrm) return false;
  const node = vrm.humanoid?.getNormalizedBoneNode(spec.bone);
  if (!node) return false;
  active.set(node, {
    startedAt: performance.now() / 1000, dur: spec.dur, axis: spec.axis,
    amp: spec.amp, hz: spec.hz, once: !!spec.once,
    rest: node.rotation[spec.axis],
  });
  return true;
}

export function update(now_s) {
  for (const [node, st] of active) {
    const t = now_s - st.startedAt;
    if (t >= st.dur) {
      node.rotation[st.axis] = st.rest;
      active.delete(node);
      continue;
    }
    const envelope = st.once
      ? Math.sin((t / st.dur) * Math.PI)                 // one-shot ease
      : Math.sin(t * st.hz * 2 * Math.PI);              // sinusoid
    node.rotation[st.axis] = st.rest + st.amp * envelope;
  }
}

export function known() { return Object.keys(bricks); }
