import Foundation

/// Procedurally synthesized nature soundscapes, with no recordings.
public enum NatureSound: Int, CaseIterable, Identifiable, Sendable {
    case none, rain, rainyStreet, ocean, sea, stream, forest, wind, fire, night, train

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .none: "Off"
        case .rain: "Rain"
        case .rainyStreet: "Rainy Street"
        case .ocean: "Ocean Surf"
        case .sea: "Seaside"
        case .stream: "Stream"
        case .forest: "Forest"
        case .wind: "Wind"
        case .fire: "Fireplace"
        case .night: "Night"
        case .train: "Old Train"
        }
    }

    public var symbol: String {
        switch self {
        case .none: "speaker.slash"
        case .rain: "cloud.rain"
        case .rainyStreet: "car"
        case .ocean: "water.waves"
        case .sea: "sailboat"
        case .stream: "drop"
        case .forest: "bird"
        case .wind: "wind"
        case .fire: "flame"
        case .night: "moon.stars"
        case .train: "tram"
        }
    }

    /// Loudness normalisation so every scene sits at a similar level.
    var gain: Double {
        switch self {
        case .none: 0
        case .rain: 1.27
        case .rainyStreet: 1.3
        case .ocean: 0.75
        case .sea: 1.0
        case .stream: 2.1
        case .forest: 2.05
        case .wind: 0.68
        case .fire: 1.15
        case .night: 2.3
        case .train: 0.9
        }
    }
}

final class NatureGen {
    private let sr: Double
    private var rng = XorShift(seed: 0xC0FFEE ^ UInt64(Date().timeIntervalSince1970))
    private var kind: NatureSound = .none
    private var fade = 0.0

    // Noise sources and generic filter state
    private var pinkL = Pink(), pinkR = Pink()
    private var brownL = 0.0, brownR = 0.0
    private var hpL = 0.0, hpR = 0.0, lpL = 0.0, lpR = 0.0, lp2L = 0.0, lp2R = 0.0, aux = 0.0

    // Slow random "wanderers" (gusts, flicker, rain intensity)
    private var gust = 0.6, gustTarget = 0.6, gustTimer = 0
    private var center = 500.0, centerTarget = 500.0, centerTimer = 0
    private var burst = 0.0

    // Short sound events: drops, bubbles, crackles
    private static let blipCount = 48
    private let blips: UnsafeMutablePointer<Blip>

    // Ocean
    private var waveP = 0.0, wavePeriod = 9.0, waveAmp = 0.8

    // Forest
    private var birds = [Bird(distance: 1), Bird(distance: 0.4)]

    // Seaside gulls
    private var gulls = [Bird(distance: 0.8, gull: true), Bird(distance: 0.45, gull: true)]

    // Rainy street
    private var cars = [Car(), Car()]
    private var carTimer = 0, carCoef = 0

    // Old train
    private var trainT = 0.0, trainPeriod = 1.5, clackIdx = 0
    private var hornTimer = 0, hornT = -1
    private static let clackOffsets = [0.0, 0.10, 0.40, 0.50]
    private static let clackAmps = [1.0, 0.8, 0.75, 0.6]

    // Night
    private var crickets: [Cricket] = []

    // Wind state-variable filters
    private var svfL = SVF(), svfR = SVF()
    private var coefCounter = 0

    // Precomputed one-pole coefficients
    private let a300, a400, a500, a600, a2k, a2500, a3k, a7k: Double

    init(sampleRate: Double) {
        sr = sampleRate
        func a(_ f: Double) -> Double { 1 - exp(-2 * .pi * f / sampleRate) }
        a300 = a(300); a400 = a(400); a500 = a(500); a600 = a(600)
        a2k = a(2000); a2500 = a(2500); a3k = a(3000); a7k = a(7000)
        blips = .allocate(capacity: Self.blipCount)
        blips.initialize(repeating: Blip(), count: Self.blipCount)
        crickets = (0..<3).map { i in
            Cricket(freq: 4200 + Double(i) * 380, pulseRate: 28 + Double(i) * 5,
                    pulses: 3 + i % 2, period: 0.55 + Double(i) * 0.17,
                    amp: [0.05, 0.035, 0.022][i], pan: [0.3, 0.7, 0.5][i])
        }
        for i in birds.indices { birds[i].wait = Int(sampleRate * (1 + Double(i) * 2.5)) }
        for i in gulls.indices { gulls[i].wait = Int(sampleRate * (2 + Double(i) * 5)) }
        carTimer = Int(sampleRate * 1.5)
        hornTimer = Int(sampleRate * 10)
    }

    deinit { blips.deallocate() }

    // MARK: Per-sample processing

    @inline(__always)
    func process(_ target: NatureSound, _ outL: inout Double, _ outR: inout Double) {
        // Crossfade between scenes.
        if target != kind {
            fade -= 1 / (0.8 * sr)
            if fade <= 0 { fade = 0; kind = target; reset() }
        } else if fade < 1 {
            fade = min(1, fade + 1 / (2.0 * sr))
        }
        guard kind != .none, fade > 0 else { return }

        let wl = rng.nextBipolar(), wr = rng.nextBipolar()
        brownL = (brownL + 0.02 * wl) / 1.02
        brownR = (brownR + 0.02 * wr) / 1.02
        let pl = pinkL.next(wl) * 0.1, pr = pinkR.next(wr) * 0.1

        wander()

        var l = 0.0, r = 0.0
        switch kind {
        case .none: break
        case .rain: rain(pl, pr, &l, &r)
        case .rainyStreet: rainyStreet(pl, pr, wl, wr, &l, &r)
        case .ocean: ocean(pl, pr, wl, wr, &l, &r)
        case .sea: sea(pl, pr, &l, &r)
        case .stream: stream(pl, pr, &l, &r)
        case .forest: forest(pl, pr, &l, &r)
        case .wind: wind(pl, pr, &l, &r)
        case .fire: fire(wl, wr, &l, &r)
        case .night: night(&l, &r)
        case .train: train(pl, pr, &l, &r)
        }
        renderBlips(&l, &r)

        let g = fade * fade * kind.gain
        outL += l * g
        outR += r * g
    }

    // MARK: Scenes

    private func rain(_ pl: Double, _ pr: Double, _ l: inout Double, _ r: inout Double) {
        // Broadband hiss: pink noise band-limited 500 Hz – 7 kHz.
        hpL += (pl - hpL) * a500; hpR += (pr - hpR) * a500
        lpL += ((pl - hpL) - lpL) * a7k; lpR += ((pr - hpR) - lpR) * a7k
        let intensity = 0.75 + 0.35 * gust
        l += lpL * 0.9 * intensity
        r += lpR * 0.9 * intensity
        // Close droplets (bright ticks) and heavier drops on leaves.
        if rng.nextUnit() < 110 * intensity / sr {
            spawn(freq: 1800 * pow(2, rng.nextUnit() * 1.6), sweep: 6, tau: 0.002 + rng.nextUnit() * 0.004,
                  amp: 0.02 + 0.12 * pow(rng.nextUnit(), 2), noise: false)
        }
        if rng.nextUnit() < 7 / sr {
            spawn(freq: 600 + rng.nextUnit() * 700, sweep: 14, tau: 0.012, amp: 0.08 + 0.08 * rng.nextUnit(), noise: false)
        }
    }

    private func ocean(_ pl: Double, _ pr: Double, _ wl: Double, _ wr: Double,
                       _ l: inout Double, _ r: inout Double) {
        waveP += 1 / (wavePeriod * sr)
        if waveP >= 1 {
            waveP -= 1
            wavePeriod = 7 + rng.nextUnit() * 6
            waveAmp = 0.55 + 0.45 * rng.nextUnit()
        }
        let swL = swell(waveP) * waveAmp
        let swR = swell(waveP + 0.06 > 1 ? waveP - 0.94 : waveP + 0.06) * waveAmp
        let cL = min(1, 2 * .pi * (220 + 2400 * swL) / sr)
        let cR = min(1, 2 * .pi * (220 + 2400 * swR) / sr)
        lpL += (pl - lpL) * cL; lp2L += (lpL - lp2L) * cL
        lpR += (pr - lpR) * cR; lp2R += (lpR - lp2R) * cR
        // Foam: high hiss on the crest.
        hpL += (wl - hpL) * a3k; hpR += (wr - hpR) * a3k
        let foamL = (wl - hpL) * swL * swL * swL * 0.03
        let foamR = (wr - hpR) * swR * swR * swR * 0.03
        l += lp2L * (0.25 + 1.4 * swL) + brownL * 0.6 + foamL
        r += lp2R * (0.25 + 1.4 * swR) + brownR * 0.6 + foamR
    }

    /// Wave envelope: quick rise, long wash back.
    @inline(__always) private func swell(_ p: Double) -> Double {
        if p < 0.3 { let s = sin(p / 0.3 * .pi / 2); return s * s }
        return exp(-(p - 0.3) * 3.5)
    }

    private func stream(_ pl: Double, _ pr: Double, _ l: inout Double, _ r: inout Double) {
        hpL += (pl - hpL) * a400; hpR += (pr - hpR) * a400
        lpL += ((pl - hpL) - lpL) * a2500; lpR += ((pr - hpR) - lpR) * a2500
        l += lpL * 0.55
        r += lpR * 0.55
        // Bubbles: short sines whose pitch rises as they resonate.
        if rng.nextUnit() < 55 / sr {
            spawn(freq: 300 * pow(2, rng.nextUnit() * 2.3), sweep: 8 + rng.nextUnit() * 25,
                  tau: 0.008 + rng.nextUnit() * 0.03, amp: 0.03 + 0.1 * rng.nextUnit(), noise: false)
        }
    }

    private func forest(_ pl: Double, _ pr: Double, _ l: inout Double, _ r: inout Double) {
        // Soft breeze plus leaf rustle.
        lpL += (brownL - lpL) * a600; lpR += (brownR - lpR) * a600
        hpL += (pl - hpL) * a2k; hpR += (pr - hpR) * a2k
        let rustle = gust * gust * 0.25
        l += lpL * 1.4 * gust + (pl - hpL) * rustle
        r += lpR * 1.4 * gust + (pr - hpR) * rustle
        for i in birds.indices {
            let (bl, br) = birds[i].next(sr: sr, rng: &rng)
            l += bl; r += br
        }
    }

    private func wind(_ pl: Double, _ pr: Double, _ l: inout Double, _ r: inout Double) {
        if coefCounter == 0 {
            svfL.set(freq: center, q: 2.2, sr: sr)
            svfR.set(freq: center * 1.17, q: 2.2, sr: sr)
        }
        coefCounter = (coefCounter + 1) & 31
        let bl = svfL.bandpass(pl * 3), br = svfR.bandpass(pr * 3)
        lpL += (brownL - lpL) * a300; lpR += (brownR - lpR) * a300
        let g = 0.15 + gust * gust
        l += (bl * 0.8 + lpL * 1.5) * g
        r += (br * 0.8 + lpR * 1.5) * g
    }

    private func fire(_ wl: Double, _ wr: Double, _ l: inout Double, _ r: inout Double) {
        lpL += (brownL - lpL) * a300; lpR += (brownR - lpR) * a300
        hpL += (wl - hpL) * a3k; hpR += (wr - hpR) * a3k
        let flicker = 0.6 + 0.4 * gust
        l += lpL * 2.2 * flicker + (wl - hpL) * 0.012 * flicker
        r += lpR * 2.2 * flicker + (wr - hpR) * 0.012 * flicker
        // Crackles come in bursts.
        if rng.nextUnit() < 0.35 / sr { burst = 1 }
        burst *= 0.99997
        if rng.nextUnit() < (4 + 40 * burst) / sr {
            spawn(freq: 0, sweep: 0, tau: 0.0005 + rng.nextUnit() * 0.0025,
                  amp: 0.04 + 0.5 * pow(rng.nextUnit(), 4), noise: true)
        }
    }

    private func rainyStreet(_ pl: Double, _ pr: Double, _ wl: Double, _ wr: Double,
                             _ l: inout Double, _ r: inout Double) {
        var rl = 0.0, rr = 0.0
        rain(pl, pr, &rl, &rr)
        l += rl * 0.75; r += rr * 0.75
        // Low city hum
        lp2L += (brownL - lp2L) * a300; lp2R += (brownR - lp2R) * a300
        l += lp2L * 0.5; r += lp2R * 0.5

        carTimer -= 1
        if carTimer <= 0 {
            carTimer = Int(sr * (2.5 + rng.nextUnit() * 9))
            if let i = cars.firstIndex(where: { !$0.active }) {
                cars[i] = Car(active: true, t: 0, dur: 4 + rng.nextUnit() * 4,
                              dir: rng.nextUnit() < 0.5 ? 1 : -1, amp: 0.5 + 0.5 * rng.nextUnit(),
                              engine: 28 + rng.nextUnit() * 22)
            }
        }
        let updateCoef = carCoef == 0
        carCoef = (carCoef + 1) & 31
        for i in cars.indices where cars[i].active {
            cars[i].t += 1 / (cars[i].dur * sr)
            if cars[i].t >= 1 { cars[i].active = false; continue }
            let x = cars[i].t
            let d = (x - 0.5) * 5
            let env = exp(-d * d)
            let doppler = 1 + 0.05 * tanh(-d * 1.5)     // higher approaching, lower receding
            if updateCoef { cars[i].svf.set(freq: 1100 * doppler, q: 0.6, sr: sr) }
            // Tyre hiss on wet tarmac: broad band-passed noise with a little spray flutter.
            let hiss = cars[i].svf.bandpass(wl) * env * cars[i].amp * 0.55 * (0.85 + 0.3 * rng.nextUnit())
            cars[i].phase += cars[i].engine * doppler / sr
            if cars[i].phase >= 1 { cars[i].phase -= 1 }
            let ph = 2 * .pi * cars[i].phase
            let engine = (sin(ph) + 0.5 * sin(2 * ph) + 0.25 * sin(3 * ph)) * env * env * cars[i].amp * 0.07
            let pan = cars[i].dir > 0 ? 0.1 + 0.8 * x : 0.9 - 0.8 * x
            let v = hiss + engine
            l += v * (1 - pan) * 1.4
            r += v * pan * 1.4
        }
    }

    private func sea(_ pl: Double, _ pr: Double, _ l: inout Double, _ r: inout Double) {
        // Gentle lapping waves: shorter, softer and darker than the surf scene.
        waveP += 1 / (wavePeriod * sr)
        if waveP >= 1 {
            waveP -= 1
            wavePeriod = 4 + rng.nextUnit() * 2.5
            waveAmp = 0.3 + 0.35 * rng.nextUnit()
        }
        let swL = swell(waveP) * waveAmp
        let swR = swell(waveP + 0.1 > 1 ? waveP - 0.9 : waveP + 0.1) * waveAmp
        let cL = min(1, 2 * .pi * (160 + 1000 * swL) / sr)
        let cR = min(1, 2 * .pi * (160 + 1000 * swR) / sr)
        lpL += (pl - lpL) * cL; lp2L += (lpL - lp2L) * cL
        lpR += (pr - lpR) * cR; lp2R += (lpR - lp2R) * cR
        l += lp2L * (0.3 + 1.6 * swL) + brownL * 0.4
        r += lp2R * (0.3 + 1.6 * swR) + brownR * 0.4
        // Water sloshing against stones as each wave arrives.
        if rng.nextUnit() < 30 * (swL + swR) / sr {
            spawn(freq: 250 * pow(2, rng.nextUnit() * 2), sweep: 10 + rng.nextUnit() * 20,
                  tau: 0.01 + rng.nextUnit() * 0.03, amp: 0.02 + 0.05 * rng.nextUnit(), noise: false)
        }
        for i in gulls.indices {
            let (gl, gr) = gulls[i].next(sr: sr, rng: &rng)
            l += gl; r += gr
        }
    }

    private func train(_ pl: Double, _ pr: Double, _ l: inout Double, _ r: inout Double) {
        // Carriage rumble with a slow sway, plus a band of rattle.
        let sway = 0.8 + 0.2 * gust
        lpL += (brownL - lpL) * a300; lpR += (brownR - lpR) * a300
        hpL += (pl - hpL) * a400; hpR += (pr - hpR) * a400
        lp2L += ((pl - hpL) - lp2L) * a2k; lp2R += ((pr - hpR) - lp2R) * a2k
        l += lpL * 2.4 * sway + lp2L * 0.35 * sway
        r += lpR * 2.4 * sway + lp2R * 0.35 * sway

        // Clickety-clack: two bogies crossing each rail joint.
        trainT += 1 / sr
        let scale = trainPeriod / 1.5
        while clackIdx < 4 && trainT >= Self.clackOffsets[clackIdx] * scale {
            let a = Self.clackAmps[clackIdx] * (0.85 + 0.15 * rng.nextUnit())
            spawn(freq: 0, sweep: 0, tau: 0.018, amp: 0.5 * a, noise: true, lp: 600)
            spawn(freq: 75, sweep: -6, tau: 0.05, amp: 0.3 * a, noise: false)
            clackIdx += 1
        }
        if trainT >= trainPeriod {
            trainT -= trainPeriod
            clackIdx = 0
            trainPeriod = min(1.9, max(1.2, trainPeriod * (0.97 + 0.06 * rng.nextUnit())))
        }
        // Occasional wheel squeal.
        if rng.nextUnit() < 0.04 / sr {
            spawn(freq: 2400 + rng.nextUnit() * 1200, sweep: -0.5, tau: 0.25, amp: 0.012, noise: false)
        }
        // Distant whistle every minute or so.
        hornTimer -= 1
        if hornTimer <= 0 { hornTimer = Int(sr * (45 + rng.nextUnit() * 60)); hornT = 0 }
        if hornT >= 0 {
            let t = Double(hornT) / sr, dur = 2.6
            let env = min(1, t / 0.25) * min(1, max(0, (dur - t) / 0.6))
            let vib = 1 + 0.003 * sin(2 * .pi * 5 * t)
            let h = (sin(2 * .pi * 330 * vib * t) + sin(2 * .pi * 415 * vib * t) + 0.8 * sin(2 * .pi * 494 * vib * t))
                * env * 0.012
            l += h * 0.7; r += h
            hornT += 1
            if t >= dur { hornT = -1 }
        }
    }

    private func night(_ l: inout Double, _ r: inout Double) {
        lpL += (brownL - lpL) * a400; lpR += (brownR - lpR) * a400
        l += lpL * 0.9
        r += lpR * 0.9
        for i in crickets.indices {
            let s = crickets[i].next(sr: sr, rng: &rng)
            l += s * (1 - crickets[i].pan)
            r += s * crickets[i].pan
        }
    }

    // MARK: Helpers

    private func wander() {
        gustTimer -= 1
        if gustTimer <= 0 {
            gustTimer = Int(sr * (1.5 + rng.nextUnit() * 4))
            gustTarget = 0.25 + 0.75 * rng.nextUnit()
        }
        gust += (gustTarget - gust) * (1.5 / sr)
        centerTimer -= 1
        if centerTimer <= 0 {
            centerTimer = Int(sr * (2 + rng.nextUnit() * 4))
            centerTarget = 250 + 650 * rng.nextUnit()
        }
        center += (centerTarget - center) * (0.8 / sr)
    }

    private func spawn(freq: Double, sweep: Double, tau: Double, amp: Double, noise: Bool, lp: Double = 0) {
        for i in 0..<Self.blipCount where !blips[i].active {
            blips[i] = Blip(freq: freq, mul: exp(sweep / sr), phase: 0, env: 1,
                            decay: exp(-1 / (tau * sr)), amp: amp,
                            pan: 0.15 + 0.7 * rng.nextUnit(), noise: noise, active: true,
                            lpA: lp > 0 ? 1 - exp(-2 * .pi * lp / sr) : 1, lpS: 0)
            return
        }
    }

    @inline(__always) private func renderBlips(_ l: inout Double, _ r: inout Double) {
        for i in 0..<Self.blipCount {
            let b = blips + i
            guard b.pointee.active else { continue }
            let s: Double
            if b.pointee.noise {
                if b.pointee.lpA < 1 {
                    b.pointee.lpS += (rng.nextBipolar() - b.pointee.lpS) * b.pointee.lpA
                    s = b.pointee.lpS * 4
                } else {
                    s = rng.nextBipolar()
                }
            } else {
                b.pointee.phase += b.pointee.freq / sr
                if b.pointee.phase >= 1 { b.pointee.phase -= 1 }
                b.pointee.freq *= b.pointee.mul
                s = sin(2 * .pi * b.pointee.phase)
            }
            let v = s * b.pointee.env * b.pointee.amp
            l += v * (1 - b.pointee.pan)
            r += v * b.pointee.pan
            b.pointee.env *= b.pointee.decay
            if b.pointee.env < 0.001 { b.pointee.active = false }
        }
    }

    private func reset() {
        hpL = 0; hpR = 0; lpL = 0; lpR = 0; lp2L = 0; lp2R = 0
        svfL = SVF(); svfR = SVF()
        for i in 0..<Self.blipCount { blips[i].active = false }
        for i in cars.indices { cars[i].active = false }
    }
}

// MARK: - Components

struct Blip {
    var freq = 0.0, mul = 1.0, phase = 0.0, env = 0.0, decay = 0.0, amp = 0.0, pan = 0.5
    var noise = false, active = false
    var lpA = 1.0, lpS = 0.0
}

struct Car {
    var active = false, t = 0.0, dur = 6.0, dir = 1.0, amp = 1.0, engine = 40.0, phase = 0.0
    var svf = SVF()
}

/// Topology-preserving state-variable filter (Simper).
struct SVF {
    private var ic1 = 0.0, ic2 = 0.0, a1 = 0.0, a2 = 0.0, a3 = 0.0
    mutating func set(freq: Double, q: Double, sr: Double) {
        let g = tan(.pi * min(freq, sr * 0.45) / sr), k = 1 / q
        a1 = 1 / (1 + g * (g + k)); a2 = g * a1; a3 = g * a2
    }
    @inline(__always) mutating func bandpass(_ x: Double) -> Double {
        let v3 = x - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1; ic2 = 2 * v2 - ic2
        return v1
    }
}

/// A songbird: waits, then sings a phrase in one of three styles.
struct Bird {
    let distance: Double
    var gull = false
    var wait = 0, notesLeft = 0, noteLen = 1, noteT = 0, gap = 0, gapLen = 0
    var style = 0, base = 3000.0, f0 = 3000.0, f1 = 3000.0
    var phase = 0.0, vibPhase = 0.0, vibRate = 0.0, vibDepth = 0.0, pan = 0.5

    init(distance: Double, gull: Bool = false) { self.distance = distance; self.gull = gull }

    mutating func next(sr: Double, rng: inout XorShift) -> (Double, Double) {
        if notesLeft == 0 {
            wait -= 1
            if wait <= 0 { startSong(sr: sr, rng: &rng) }
            return (0, 0)
        }
        if gap > 0 { gap -= 1; return (0, 0) }
        let t = Double(noteT) / Double(noteLen)
        let f = (f0 + (f1 - f0) * t) * (1 + vibDepth * sin(2 * .pi * vibPhase))
        vibPhase += vibRate / sr; if vibPhase >= 1 { vibPhase -= 1 }
        phase += f / sr; if phase >= 1 { phase -= 1 }
        let e = sin(.pi * t)
        let p = 2 * .pi * phase
        let tone = gull ? (sin(p) + 0.45 * sin(2 * p) + 0.25 * sin(3 * p)) * 0.6 : sin(p)
        let s = tone * e * e * 0.07 * distance
        noteT += 1
        if noteT >= noteLen {
            noteT = 0; notesLeft -= 1; gap = gapLen
            nextNote(sr: sr, rng: &rng)
            if notesLeft == 0 {
                wait = Int(sr * (gull ? 5 + rng.nextUnit() * 12 : 2 + rng.nextUnit() * 7 / distance))
            }
        }
        return (s * (1 - pan), s * pan)
    }

    private mutating func startSong(sr: Double, rng: inout XorShift) {
        style = gull ? 3 : Int.random(in: 0..<3, using: &rng)
        pan = 0.1 + 0.8 * rng.nextUnit()
        switch style {
        case 3: notesLeft = Int.random(in: 2...5, using: &rng); base = 1000 + rng.nextUnit() * 500
        case 0: notesLeft = Int.random(in: 2...4, using: &rng); base = 2000 + rng.nextUnit() * 1500
        case 1: notesLeft = Int.random(in: 6...14, using: &rng); base = 3500 + rng.nextUnit() * 2000
        default: notesLeft = Int.random(in: 2...5, using: &rng); base = 2600 + rng.nextUnit() * 1800
        }
        nextNote(sr: sr, rng: &rng)
    }

    private mutating func nextNote(sr: Double, rng: inout XorShift) {
        switch style {
        case 0: // whistle: long slides
            noteLen = Int(sr * (0.15 + rng.nextUnit() * 0.2))
            gapLen = Int(sr * (0.08 + rng.nextUnit() * 0.12))
            f0 = base * (0.85 + rng.nextUnit() * 0.3); f1 = base * (0.85 + rng.nextUnit() * 0.3)
            vibDepth = 0.004; vibRate = 6
        case 1: // trill: fast repeated down-chirps
            noteLen = Int(sr * (0.03 + rng.nextUnit() * 0.02))
            gapLen = Int(sr * (0.02 + rng.nextUnit() * 0.02))
            f0 = base * 1.12; f1 = base * 0.88
            vibDepth = 0; vibRate = 0
        case 3: // gull: harsh descending "kee-ow"
            noteLen = Int(sr * (0.22 + rng.nextUnit() * 0.18))
            gapLen = Int(sr * (0.08 + rng.nextUnit() * 0.15))
            f0 = base * 1.25; f1 = base * 0.8
            vibDepth = 0.03; vibRate = 18
        default: // chirps: rising with buzz
            noteLen = Int(sr * (0.06 + rng.nextUnit() * 0.06))
            gapLen = Int(sr * (0.06 + rng.nextUnit() * 0.09))
            f0 = base * 0.8; f1 = base * 1.3
            vibDepth = 0.02; vibRate = 40
        }
    }
}

/// A cricket: chirps of a few rapid pulses on a ~4–5 kHz carrier.
struct Cricket {
    let freq, pulseRate: Double
    let pulses: Int
    var period: Double
    let amp, pan: Double
    var t = 0, phase = 0.0

    init(freq: Double, pulseRate: Double, pulses: Int, period: Double, amp: Double, pan: Double) {
        self.freq = freq; self.pulseRate = pulseRate; self.pulses = pulses
        self.period = period; self.amp = amp; self.pan = pan
    }

    mutating func next(sr: Double, rng: inout XorShift) -> Double {
        let tc = Double(t) / sr * pulseRate
        let idx = Int(tc)
        var gate = 0.0
        if idx < pulses {
            let pp = tc - Double(idx)
            if pp < 0.6 { let s = sin(.pi * pp / 0.6); gate = s * s }
        }
        phase += freq / sr; if phase >= 1 { phase -= 1 }
        t += 1
        if Double(t) >= period * sr { t = 0; period = min(1.3, max(0.35, period * (0.95 + rng.nextUnit() * 0.1))) }
        return sin(2 * .pi * phase) * gate * amp
    }
}
