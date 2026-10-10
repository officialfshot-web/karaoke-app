// Offline checks for the Studio FX engine. Run: node dsp/test.mjs
import { StudioFX, PRESETS } from './studio.mjs';

const fs = 48000;
let failed = 0;
const check = (ok, msg) => { console.log(`${ok ? 'PASS' : 'FAIL'}  ${msg}`); if (!ok) failed++; };
const run = (fx, input) => { const L = new Float32Array(input.length), R = new Float32Array(input.length); fx.process(input, L, R); return [L, R]; };
const db = x => 20 * Math.log10(x + 1e-12);
const rmsOf = (a, from = 0, to = a.length) => { let s = 0; for (let i = from; i < to; i++) s += a[i] * a[i]; return Math.sqrt(s / Math.max(1, to - from)); };
const sine = (f, amp, secs) => Float32Array.from({ length: fs * secs }, (_, i) => amp * Math.sin(2 * Math.PI * f * i / fs));

// 1. dry path adds no delay
{
  const fx = new StudioFX(fs); fx.applyPreset('clean', 0, 0);
  const imp = new Float32Array(256); imp[0] = 0.3;
  const [L] = run(fx, imp);
  let peak = 0; for (let i = 1; i < 256; i++) if (Math.abs(L[i]) > Math.abs(L[peak])) peak = i;
  check(peak === 0, `dry path latency = ${peak} samples (want 0)`);
}

// 2. every preset is stable and its reverb dies away
for (const name of Object.keys(PRESETS)) {
  const fx = new StudioFX(fs); fx.applyPreset(name, 2, 2);   // sliders maxed: worst case
  const burst = new Float32Array(fs * 9);
  for (let i = 0; i < fs * 0.4; i++) burst[i] = (Math.random() * 2 - 1) * 0.5;
  const [L, R] = run(fx, burst);
  let finite = true, peak = 0;
  for (let i = 0; i < L.length; i++) { if (!Number.isFinite(L[i]) || !Number.isFinite(R[i])) { finite = false; break; } peak = Math.max(peak, Math.abs(L[i]), Math.abs(R[i])); }
  const tail = rmsOf(L, fs * 8, fs * 9), body = rmsOf(L, fs * 0.4, fs * 0.6);
  // time for the tail to fall 30 dB after the burst, x2 ≈ RT60
  let t30 = 0; const blk = fs / 50;
  for (let i = fs * 0.45; i + blk < L.length; i += blk) if (db(rmsOf(L, i, i + blk)) < db(body) - 30) { t30 = (i - fs * 0.4) / fs; break; }
  check(finite && peak <= 1, `${name.padEnd(9)} stable (peak ${peak.toFixed(2)}), decays: ~RT60 ${(2 * t30).toFixed(1)}s (target ${PRESETS[name].rv[1]}s), tail at 8s ${db(tail).toFixed(0)} dB`);
  check(db(tail) < db(body) - 55, `${name.padEnd(9)} tail fully gone`);
}

// 3. de-esser pulls down harsh "s" more than the body of the voice
{
  const loud = (f) => { const fx = new StudioFX(fs); fx.applyPreset('studio', 0, 0); const [L] = run(fx, sine(f, 0.4, 0.5)); return db(rmsOf(L, fs * 0.3)); };
  const sib = loud(7500) - db(0.4 / Math.SQRT2), body = loud(800) - db(0.4 / Math.SQRT2);
  check(sib < body - 3, `de-esser: 7.5 kHz ${sib.toFixed(1)} dB vs 800 Hz ${body.toFixed(1)} dB (want ≥3 dB less)`);
}

// 4. compressor evens out loud vs soft singing
{
  const out = amp => { const fx = new StudioFX(fs); fx.applyPreset('studio', 0, 0); const [L] = run(fx, sine(300, amp, 0.6)); return db(rmsOf(L, fs * 0.4)); };
  const spreadIn = db(0.5) - db(0.03), spreadOut = out(0.5) - out(0.03);
  check(spreadOut < spreadIn - 6, `compressor: ${spreadIn.toFixed(0)} dB input range → ${spreadOut.toFixed(1)} dB output`);
}

// 5. fast enough for real time (well under 1x)
{
  const fx = new StudioFX(fs); fx.applyPreset('arena');
  const x = sine(220, 0.3, 10), t0 = performance.now(); run(fx, x);
  const ms = performance.now() - t0;
  check(ms < 2000, `speed: 10 s of audio in ${ms.toFixed(0)} ms (${(10000 / ms).toFixed(0)}x real time)`);
}

console.log(failed ? `\n${failed} check(s) failed` : '\nall checks passed');
process.exit(failed ? 1 : 0);
