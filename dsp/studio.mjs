// Reference implementation of the Studio FX vocal engine. ios/StudioFX (Swift) is a line-by-line port of this;
// dsp/test.js runs it offline to check stability, latency and decay before it ever reaches a phone.
// Mono voice in → stereo out:
//   compressor → de-esser → tape warmth → [dry]
//                                       ├→ doubler (2 modulated voices, L/R)  — no pitch shifter, so no added delay
//                                       ├→ ping-pong echo (filtered, ducks while you sing)
//                                       └→ reverb: pre-delay → diffusers → 8-line feedback delay network (damped, modulated)
//   → width → soft limiter

const TAU = Math.PI * 2;
const dbToLin = d => Math.pow(10, d / 20);

class Biquad {
  constructor() { this.b0 = 1; this.b1 = this.b2 = this.a1 = this.a2 = 0; this.z1 = this.z2 = 0; }
  set(type, fs, f, q = 0.7071, gainDb = 0) {
    const w = TAU * Math.min(f, fs * 0.45) / fs, c = Math.cos(w), s = Math.sin(w), al = s / (2 * q), A = Math.pow(10, gainDb / 40);
    let b0, b1, b2, a0, a1, a2;
    if (type === 'lp') { b0 = (1 - c) / 2; b1 = 1 - c; b2 = b0; a0 = 1 + al; a1 = -2 * c; a2 = 1 - al; }
    else if (type === 'hp') { b0 = (1 + c) / 2; b1 = -(1 + c); b2 = b0; a0 = 1 + al; a1 = -2 * c; a2 = 1 - al; }
    else if (type === 'bp') { b0 = al; b1 = 0; b2 = -al; a0 = 1 + al; a1 = -2 * c; a2 = 1 - al; }
    else { // peak
      b0 = 1 + al * A; b1 = -2 * c; b2 = 1 - al * A; a0 = 1 + al / A; a1 = -2 * c; a2 = 1 - al / A;
    }
    this.b0 = b0 / a0; this.b1 = b1 / a0; this.b2 = b2 / a0; this.a1 = a1 / a0; this.a2 = a2 / a0;
  }
  run(x) { // transposed direct form II
    const y = this.b0 * x + this.z1;
    this.z1 = this.b1 * x - this.a1 * y + this.z2;
    this.z2 = this.b2 * x - this.a2 * y;
    return y;
  }
}

class OnePole { // y += a (x - y)
  constructor() { this.a = 1; this.y = 0; }
  setLP(fs, f) { this.a = 1 - Math.exp(-TAU * f / fs); }
  lp(x) { this.y += this.a * (x - this.y); return this.y; }
  hp(x) { return x - this.lp(x); }
}

class Delay { // power-of-two ring buffer with fractional (linear) reads
  constructor(maxSamples) {
    let n = 1; while (n < maxSamples + 2) n <<= 1;
    this.buf = new Float32Array(n); this.mask = n - 1; this.w = 0;
  }
  write(x) { this.buf[this.w] = x; this.w = (this.w + 1) & this.mask; }
  read(d) { // d samples ago (d >= 1)
    const i = Math.floor(d), f = d - i;
    const a = this.buf[(this.w - i) & this.mask], b = this.buf[(this.w - i - 1) & this.mask];
    return a + (b - a) * f;
  }
}

class Allpass { // Schroeder allpass diffuser
  constructor(len, g) { this.d = new Delay(len); this.len = len; this.g = g; }
  run(x) {
    const v = this.d.read(this.len);
    const u = x + this.g * v;
    this.d.write(u);
    return v - this.g * u;
  }
}

export const PRESETS = {
  //          de-ess  comp thr/ratio  warmth  double  echo time/fb/mix          reverb size/decay/damp/pre/mix   width
  clean:     { deess: 4, thr: -18, ratio: 2.5, warm: .10, dbl: 0,   dly: [.0,  0,  0],   rv: [.55, .9, .55, 8, .08],  width: .6 },
  studio:    { deess: 6, thr: -22, ratio: 3.5, warm: .25, dbl: 0,   dly: [.0,  0,  0],   rv: [.75, 1.6, .5, 22, .16], width: .8 },
  pop:       { deess: 7, thr: -26, ratio: 4,   warm: .30, dbl: .30, dly: [.25, .28, .12], rv: [.8, 1.9, .45, 28, .18], width: 1 },
  rnb:       { deess: 6, thr: -26, ratio: 3.5, warm: .35, dbl: .20, dly: [.36, .32, .10], rv: [.9, 2.6, .55, 35, .22], width: 1 },
  arena:     { deess: 5, thr: -20, ratio: 3,   warm: .20, dbl: .12, dly: [.42, .40, .16], rv: [1.0, 3.4, .5, 45, .30], width: 1 },
  vintage:   { deess: 4, thr: -18, ratio: 3,   warm: .55, dbl: 0,   dly: [.11, .05, .20], rv: [.7, 1.4, .75, 12, .18], width: .5 },
  cathedral: { deess: 5, thr: -20, ratio: 3,   warm: .15, dbl: 0,   dly: [.0,  0,  0],   rv: [1.0, 5.5, .6, 60, .36], width: 1 },
};

export class StudioFX {
  constructor(fs) {
    this.fs = fs;
    const ms = x => Math.round(x * fs / 1000);
    // de-esser: complementary split at 6.5 kHz, sidechain on the band where "s" lives
    this.split = new Biquad(); this.split.set('lp', fs, 4800, 0.5);
    this.sib = new Biquad(); this.sib.set('bp', fs, 7000, 1.2);
    this.deEnv = 0; this.fullEnv = 0;
    // compressor: RMS detector, soft knee, attack/release in the gain domain
    this.rms = 0; this.gr = 0;
    this.rmsA = 1 - Math.exp(-1 / (0.006 * fs));
    this.attA = 1 - Math.exp(-1 / (0.004 * fs));
    this.relA = 1 - Math.exp(-1 / (0.14 * fs));
    this.env = 0; this.envA = 1 - Math.exp(-1 / (0.03 * fs)); // voice-activity envelope (ducking)
    // doubler: two voices around 13 ms, gently wobbling ±0.9 ms
    this.dblLine = new Delay(ms(30)); this.lfo1 = 0; this.lfo2 = 0.37; this.dblHP = new OnePole(); this.dblHP.setLP(fs, 180);
    // ping-pong echo
    this.dL = new Delay(ms(1100)); this.dR = new Delay(ms(1100));
    this.fbHP_L = new OnePole(); this.fbHP_L.setLP(fs, 280); this.fbLP_L = new OnePole(); this.fbLP_L.setLP(fs, 4500);
    this.fbHP_R = new OnePole(); this.fbHP_R.setLP(fs, 280); this.fbLP_R = new OnePole(); this.fbLP_R.setLP(fs, 4500);
    // reverb
    this.pre = new Delay(ms(120));
    this.rvHP = new OnePole(); this.rvHP.setLP(fs, 220); this.rvLP = new OnePole(); this.rvLP.setLP(fs, 8500);
    const sc = fs / 44100;
    this.diff = [142, 107, 379, 277].map(n => new Allpass(Math.round(n * sc), 0.7));
    this.baseLens = [1557, 1617, 1491, 1422, 1277, 1356, 1188, 1116].map(n => n * sc);
    this.lines = this.baseLens.map(n => new Delay(Math.ceil(n * 1.3) + 64));
    this.damp = this.baseLens.map(() => 0);
    this.fdnState = new Float32Array(8);
    this.modPh = 0;
    this.p = { ...PRESETS.studio }; this.reverbAmt = 1; this.echoAmt = 1;
    this.mix = { dbl: 0, dly: 0, rv: 0 };  // smoothed sends
    this.applyPreset('studio');
  }

  applyPreset(name, reverbAmt = 1, echoAmt = 1) {
    this.p = { ...PRESETS[name] || PRESETS.studio };
    this.reverbAmt = reverbAmt; this.echoAmt = echoAmt;
    const [size, decay, damp] = this.p.rv;
    this.lens = this.baseLens.map(n => n * (0.6 + 0.4 * size));
    // per-line feedback gain for the requested decay (RT60): g = 10^(-3 * len / (fs * RT60))
    this.gains = this.lens.map(n => Math.pow(10, -3 * n / (this.fs * decay)));
    this.dampA = 1 - Math.exp(-TAU * (2500 + (1 - damp) * 9000) / this.fs);
    this.makeup = dbToLin(-this.p.thr * (1 - 1 / this.p.ratio) * 0.45);
  }

  // in: Float32Array mono voice; outL/outR: Float32Array (may alias nothing). Same length.
  process(input, outL, outR) {
    const p = this.p, fs = this.fs;
    const [dTime, dFb, dMix] = p.dly, [, , , preMs, rvMix] = p.rv;
    const preSamp = Math.max(1, preMs * fs / 1000), dSamp = Math.max(1, dTime * fs);
    const tDbl = p.dbl, tDly = dMix * this.echoAmt, tRv = Math.min(0.6, rvMix * this.reverbAmt);
    const thr = p.thr, slope = 1 - 1 / p.ratio, knee = 6;
    const deMax = p.deess;
    const warm = p.warm, drive = 1 + warm * 3, norm = 1 / Math.tanh(drive);
    const w = p.width, sm = 0.0015;
    const H = 1 / Math.sqrt(8);
    for (let n = 0; n < input.length; n++) {
      let x = input[n];

      // --- compressor (soft knee)
      this.rms += this.rmsA * (x * x - this.rms);
      const lvl = 10 * Math.log10(this.rms + 1e-12);
      let want = 0;
      const d = lvl - thr;
      if (d > knee / 2) want = d * slope;
      else if (d > -knee / 2) want = slope * (d + knee / 2) ** 2 / (2 * knee);
      this.gr += (want > this.gr ? this.attA : this.relA) * (want - this.gr);
      x *= dbToLin(-this.gr) * this.makeup;
      this.env += this.envA * (Math.abs(x) - this.env);

      // --- de-esser: when the "s" band is loud *relative to the voice*, turn the top band down
      // (level-independent, and after the compressor so it can't be undone by it)
      const lo = this.split.run(x), hi = x - lo;
      const sb = Math.abs(this.sib.run(x)), ax = Math.abs(x);
      this.deEnv += (sb > this.deEnv ? 0.3 : 0.0015) * (sb - this.deEnv);
      this.fullEnv += (ax > this.fullEnv ? 0.3 : 0.0015) * (ax - this.fullEnv);
      const ratio = this.deEnv / (0.3 * this.fullEnv + 1e-5);
      const over = ratio > 1 ? Math.min(deMax, 20 * Math.log10(ratio) * 1.2) : 0;
      x = lo + hi * dbToLin(-over);

      // --- tape warmth: gentle saturation blended in
      if (warm > 0) x = x * (1 - warm) + Math.tanh(x * drive) * norm * warm;
      const dry = x;

      // smooth the sends so preset/slider changes never click
      this.mix.dbl += sm * (tDbl - this.mix.dbl); this.mix.dly += sm * (tDly - this.mix.dly); this.mix.rv += sm * (tRv - this.mix.rv);

      // --- doubler
      this.dblLine.write(dry);
      this.lfo1 += 0.31 / fs; if (this.lfo1 >= 1) this.lfo1 -= 1;
      this.lfo2 += 0.47 / fs; if (this.lfo2 >= 1) this.lfo2 -= 1;
      const base = 0.013 * fs, dev = 0.0009 * fs;
      const v1 = this.dblHP.hp(this.dblLine.read(base + dev * Math.sin(TAU * this.lfo1)));
      const v2 = this.dblLine.read(base * 1.27 + dev * Math.sin(TAU * this.lfo2));
      const dblL = v1 * this.mix.dbl, dblR = (v2 - (v1 - v2) * 0) * this.mix.dbl;

      // --- ping-pong echo, quieter while you sing, blooming in the gaps
      let eL = 0, eR = 0;
      if (this.mix.dly > 1e-4) {
        const rl = this.dL.read(dSamp), rr = this.dR.read(dSamp);
        const fl = this.fbLP_L.lp(this.fbHP_L.hp(rl)), fr = this.fbLP_R.lp(this.fbHP_R.hp(rr));
        this.dL.write(dry + fr * dFb);
        this.dR.write(fl * dFb);
        const duck = 1 - Math.min(0.7, this.env * 6);
        eL = fl * this.mix.dly * duck; eR = fr * this.mix.dly * duck;
      } else { this.dL.write(0); this.dR.write(0); }

      // --- reverb (feedback delay network)
      this.pre.write(dry);
      let r = this.rvLP.lp(this.rvHP.hp(this.pre.read(preSamp)));
      for (const ap of this.diff) r = ap.run(r);
      this.modPh += 0.5 / fs; if (this.modPh >= 1) this.modPh -= 1;
      const mod = Math.sin(TAU * this.modPh) * 6;
      const st = this.fdnState;
      for (let i = 0; i < 8; i++) {
        let y = this.lines[i].read(this.lens[i] + (i < 2 ? (i ? -mod : mod) : 0));
        this.damp[i] += this.dampA * (y - this.damp[i]);
        st[i] = this.damp[i] * this.gains[i];
      }
      // Hadamard mix (fast, 8 points)
      const a0 = st[0] + st[1], a1 = st[0] - st[1], a2 = st[2] + st[3], a3 = st[2] - st[3];
      const a4 = st[4] + st[5], a5 = st[4] - st[5], a6 = st[6] + st[7], a7 = st[6] - st[7];
      const b0 = a0 + a2, b1 = a1 + a3, b2 = a0 - a2, b3 = a1 - a3, b4 = a4 + a6, b5 = a5 + a7, b6 = a4 - a6, b7 = a5 - a7;
      const m = [b0 + b4, b1 + b5, b2 + b6, b3 + b7, b0 - b4, b1 - b5, b2 - b6, b3 - b7];
      for (let i = 0; i < 8; i++) this.lines[i].write(m[i] * H + r * 0.35);
      let rL = (st[0] - st[2] + st[4] - st[6]) * 0.5, rR = (st[1] - st[3] + st[5] - st[7]) * 0.5;
      const rduck = 1 - Math.min(0.35, this.env * 3);
      rL *= this.mix.rv * rduck; rR *= this.mix.rv * rduck;

      // --- width on the effects only, then mix and a soft safety limiter (no look-ahead = no delay)
      let wl = dblL + eL + rL, wr = dblR + eR + rR;
      const mid = (wl + wr) * 0.5, side = (wl - wr) * 0.5 * w;
      wl = mid + side; wr = mid - side;
      outL[n] = soft(dry + wl);
      outR[n] = soft(dry + wr);
    }
  }
}

function soft(x) { // transparent below 0.8, rounds off above, never exceeds 1
  const a = Math.abs(x);
  if (a <= 0.8) return x;
  return Math.sign(x) * (0.8 + 0.2 * Math.tanh((a - 0.8) / 0.2));
}
