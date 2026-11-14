import Foundation

/// Real-time generative music synthesizer.
///
/// A 16th-note sequencer drives a Markov chord progression. Depending on the `Track`
/// it plays pads, Rhodes-style electric piano, a piano, arpeggios, a sub or plucked
/// bass, synthesized drums and vinyl crackle. The music bus is amplitude-modulated at
/// the `Mode`'s target rate. Nature sounds and the noise bed are mixed in afterwards
/// and are not modulated.
///
/// `render` runs on the audio thread and does not allocate. Control properties are plain
/// word-sized values written from the main thread and read once per buffer.
public final class Synth: @unchecked Sendable {

    // MARK: Controls (written from the UI thread)

    public var mode: Mode = .focus
    public var track: Track = .ambient
    public var nature: NatureSound = .none
    /// Scales the modulation depth, 0...1.
    public var intensity: Double = 0.7
    public var volume: Double = 0.7
    public var musicLevel: Double = 1.0
    public var natureLevel: Double = 0.6
    /// Level of the plain noise bed, 0...1.
    public var ambience: Double = 0.15
    public var isPlaying: Bool = false
    public var fadeSeconds: Double = 2.0

    /// True while any sound is coming out (including a fade-out tail).
    public var isAudible: Bool { masterGain > 0.0001 }

    public let sampleRate: Double

    // MARK: Constants

    private static let padCount = 16
    private static let noteCount = 32
    private static let tableSize = 4096
    private static let triad = [0, 2, 4]
    private static let melodyOffsets = [0, 1, 2, 4]
    private static let degreeWeights: [Double] = [3, 2, 1, 3, 2.5, 2.5, 1]
    private static let pianoPattern = [0, 2, 1, 3, 2, 1, 3, 2]

    // MARK: State

    private var rng = XorShift(seed: UInt64(Date().timeIntervalSince1970 * 1000))
    private var masterGain = 0.0

    private var activeMode: Mode = .focus
    private var activeTrack: Track = .ambient
    private var tp: TrackParams = Track.ambient.params
    private var scale: [Int]
    private var rootMidi: Int

    // Smoothed parameters
    private var amRate: Double, amDepth = 0.0, amPhase = 0.0
    private var bpm: Double, brightness: Double, reverbMix: Double
    private var noiseColor: Double, pluckDensity: Double
    private var padLevel = 1.0, bassLevel = 1.0, crackle = 0.0, wobble = 0.0, trackGain = 1.0

    // Sequencer
    private var samplesToNextStep = 0.0
    private var step = 0
    private var barCount = 0
    private var drumsMutedBars = 0
    private var chordDegree = 0
    private var phraseDensity = 1.0
    private var melodyIndex = 4
    private var arpIndex = 0
    private let melody: UnsafeMutablePointer<Double>
    private var melodyCount = 0
    private let chord: UnsafeMutablePointer<Double>   // 4 chord-tone frequencies, ascending

    // Voices
    private let pads: UnsafeMutablePointer<Pad>
    private let notes: UnsafeMutablePointer<Note>
    private var bassFreq = 55.0, bassTarget = 55.0, bassPhase = 0.0
    private var bassEnv = 0.0, bassAtk = 1.0, bassVel = 1.0

    // Drums
    private var kickEnv = 0.0, kickPitch = 0.0, kickPhase = 0.0, kickVel = 0.0
    private var snareEnv = 0.0, snareTone = 0.0, snarePhase = 0.0, snareVel = 0.0, snareLP = 0.0
    private var hatEnv = 0.0, hatVel = 0.0, hatLP = 0.0, hatDark = 0.0, hatDecay = 0.0
    private var duck = 0.0

    private let warmTable: UnsafeMutablePointer<Float>

    // Filters / LFOs / noise
    private var lfoPhase = 0.0, wobPhase = 0.0
    private var padLP1 = (0.0, 0.0), padLP2 = (0.0, 0.0)
    private var noiseLP = (0.0, 0.0)
    private var pinkL = Pink(), pinkR = Pink()
    private var brownL = 0.0, brownR = 0.0
    private var crackleEnv = 0.0, crackleLP = 0.0

    // Effects
    private let echoL: DelayLine, echoR: DelayLine
    private let reverbL: Freeverb, reverbR: Freeverb
    private let natureGen: NatureGen

    // Coefficients
    private let padAttack: Double, padRelease: Double, bassCoef: Double, glideCoef: Double
    private let kickDecay: Double, kickPitchDecay: Double
    private let snareDecay: Double, snareToneDecay: Double
    private let hatClosed: Double, hatOpen: Double, duckDecay: Double
    private let a1500: Double, a7000: Double, a5000: Double

    // MARK: Init

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let p = Mode.focus.params
        scale = p.scale
        rootMidi = p.rootMidi
        amRate = p.amRate
        bpm = p.bpm
        brightness = p.brightness
        reverbMix = p.reverbMix
        noiseColor = p.noiseColor
        pluckDensity = p.pluckDensity

        pads = .allocate(capacity: Self.padCount)
        pads.initialize(repeating: Pad(), count: Self.padCount)
        notes = .allocate(capacity: Self.noteCount)
        notes.initialize(repeating: Note(), count: Self.noteCount)
        melody = .allocate(capacity: 16)
        melody.initialize(repeating: 440, count: 16)
        chord = .allocate(capacity: 4)
        chord.initialize(repeating: 220, count: 4)

        // Warm, mellow waveform: harmonics falling off at 1/n^1.6.
        warmTable = .allocate(capacity: Self.tableSize + 1)
        var peak: Float = 0
        for i in 0...Self.tableSize {
            let x = Double(i) / Double(Self.tableSize) * 2 * .pi
            var v = 0.0
            for n in 1...8 { v += sin(Double(n) * x) / pow(Double(n), 1.6) }
            warmTable[i] = Float(v)
            peak = max(peak, abs(Float(v)))
        }
        for i in 0...Self.tableSize { warmTable[i] /= peak }

        echoL = DelayLine(capacity: Int(sampleRate * 3))
        echoR = DelayLine(capacity: Int(sampleRate * 3))
        reverbL = Freeverb(sampleRate: sampleRate, spread: 0)
        reverbR = Freeverb(sampleRate: sampleRate, spread: 23)
        natureGen = NatureGen(sampleRate: sampleRate)

        func coef(_ tau: Double) -> Double { 1 - exp(-1 / (tau * sampleRate)) }
        func decay(_ tau: Double) -> Double { exp(-1 / (tau * sampleRate)) }
        func lp(_ f: Double) -> Double { 1 - exp(-2 * .pi * f / sampleRate) }
        padAttack = coef(1.6)
        padRelease = coef(2.6)
        bassCoef = coef(2.0)
        glideCoef = coef(0.8)
        kickDecay = decay(0.28); kickPitchDecay = decay(0.035)
        snareDecay = decay(0.09); snareToneDecay = decay(0.05)
        hatClosed = decay(0.028); hatOpen = decay(0.11)
        duckDecay = decay(0.13)
        a1500 = lp(1500); a7000 = lp(7000); a5000 = lp(5000)
    }

    deinit {
        pads.deallocate(); notes.deallocate(); melody.deallocate()
        chord.deallocate(); warmTable.deallocate()
    }

    // MARK: Render

    public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        // Snapshot controls once per buffer.
        let mp = mode.params
        let tt = track.params
        let depthTarget = mp.amDepth * clamp(intensity)
        let vol = clamp(volume)
        let musicTarget = clamp(musicLevel)
        let natureGain = clamp(natureLevel) * clamp(natureLevel)
        let natureTarget = nature
        let amb = clamp(ambience)
        let gainTarget = isPlaying ? 1.0 : 0.0
        let gainStep = 1.0 / max(0.01, fadeSeconds) / sampleRate

        // Glide per buffer (time constants of a few seconds).
        let k = 1 - exp(-Double(frames) / (3.0 * sampleRate))
        let bpmTarget = min(tt.maxBpm, max(tt.minBpm, mp.bpm * tt.tempoScale))
        amRate += (mp.amRate - amRate) * k
        amDepth += (depthTarget - amDepth) * min(1, k * 3)
        bpm += (bpmTarget - bpm) * k
        brightness += (min(1, mp.brightness * tt.brightness) - brightness) * k
        reverbMix += (min(0.7, mp.reverbMix * tt.reverbScale) - reverbMix) * k
        noiseColor += (mp.noiseColor - noiseColor) * k
        pluckDensity += (mp.pluckDensity - pluckDensity) * k
        padLevel += (tt.padLevel - padLevel) * k
        bassLevel += (tt.bassLevel - bassLevel) * k
        crackle += (tt.crackle - crackle) * k
        wobble += (tt.wobble - wobble) * k
        trackGain += (tt.gain - trackGain) * min(1, k * 3)

        let music = musicTarget * trackGain
        let sr = sampleRate
        let amInc = amRate / sr
        let lfoInc = 1.0 / 47.0 / sr          // slow filter sweep, 47 s cycle
        let sixteenth = sr * 15 / bpm
        let echoTime = sixteenth * 6          // dotted quarter
        let wet = reverbMix
        let darkHats = tp.drums == .lofi
        let bassPluckDecay = exp(-1 / ((tp.drums == .house ? 0.16 : 0.45) * sr))
        let nA = 1 - exp(-2 * .pi * (900 + 3000 * brightness) / sr)

        for i in 0..<frames {
            // Sequencer (swing lengthens even 16ths, shortens odd ones)
            samplesToNextStep -= 1
            if samplesToNextStep <= 0 {
                let sw = step % 2 == 0 ? 1 + tp.swing : 1 - tp.swing
                samplesToNextStep += sixteenth * sw
                tick()
            }

            // LFOs
            lfoPhase += lfoInc; if lfoPhase >= 1 { lfoPhase -= 1 }
            wobPhase += 0.55 / sr; if wobPhase >= 1 { wobPhase -= 1 }
            let cutoff = (350 + 2200 * brightness * brightness) * (1 + 0.35 * sin(2 * .pi * lfoPhase))
            let lpA = 1 - exp(-2 * .pi * cutoff / sr)
            let pitchMul = 1 + wobble * sin(2 * .pi * wobPhase)

            // Pads
            var padL = 0.0, padR = 0.0
            for v in 0..<Self.padCount {
                let pv = pads + v
                guard pv.pointee.active else { continue }
                let c = pv.pointee.target > pv.pointee.env ? padAttack : padRelease
                pv.pointee.env += (pv.pointee.target - pv.pointee.env) * c
                if pv.pointee.target == 0 && pv.pointee.env < 0.0005 { pv.pointee.active = false; continue }
                let f = pv.pointee.freq / sr
                pv.pointee.p1 = wrap(pv.pointee.p1 + f * 0.9960)   // −7 cents
                pv.pointee.p2 = wrap(pv.pointee.p2 + f * 1.0040)   // +7 cents
                pv.pointee.p3 = wrap(pv.pointee.p3 + f * 2.0010)   // shimmer octave
                let a = table(pv.pointee.p1), b = table(pv.pointee.p2)
                let s = sin(2 * .pi * pv.pointee.p3) * 0.18
                let e = pv.pointee.env * 0.075
                padL += (a + 0.55 * b + s) * e
                padR += (b + 0.55 * a + s) * e
            }
            padLP1.0 += (padL - padLP1.0) * lpA; padLP2.0 += (padLP1.0 - padLP2.0) * lpA
            padLP1.1 += (padR - padLP1.1) * lpA; padLP2.1 += (padLP1.1 - padLP2.1) * lpA
            duck *= duckDecay
            let padGain = padLevel * (1 - 0.55 * duck)

            // Bass
            if tp.bassPlucked {
                bassFreq = bassTarget
                bassEnv *= bassPluckDecay
                bassAtk += (1 - bassAtk) * 0.01
            } else {
                bassFreq += (bassTarget - bassFreq) * glideCoef
                bassEnv += (1 - bassEnv) * bassCoef
                bassAtk = 1; bassVel += (1 - bassVel) * bassCoef
            }
            bassPhase = wrap(bassPhase + bassFreq / sr)
            let be = bassEnv * bassAtk
            let bass = (sin(2 * .pi * bassPhase) + 0.18 * sin(4 * .pi * bassPhase)
                        + 0.12 * be * sin(6 * .pi * bassPhase)) * 0.11 * bassLevel * be * bassVel

            // Notes (bells, electric piano, piano, arpeggio)
            var nL = 0.0, nR = 0.0
            for v in 0..<Self.noteCount {
                let nv = notes + v
                guard nv.pointee.active else { continue }
                if nv.pointee.delay > 0 { nv.pointee.delay -= 1; continue }
                nv.pointee.env *= nv.pointee.decay
                nv.pointee.atk += (1 - nv.pointee.atk) * nv.pointee.atkCoef
                let env = nv.pointee.env
                if env < 0.0003 { nv.pointee.active = false; continue }
                nv.pointee.phase = wrap(nv.pointee.phase + nv.pointee.freq * pitchMul / sr)
                let ph = 2 * .pi * nv.pointee.phase
                var s: Double
                switch nv.pointee.kind {
                case .bell:
                    s = sin(ph) + 0.3 * env * sin(2 * ph) + 0.08 * env * sin(3 * ph)
                case .ep:
                    let fast = env * env
                    s = sin(ph + (0.15 + 1.1 * fast) * sin(ph)) + 0.1 * fast * fast * sin(7 * ph)
                case .piano:
                    let e2 = env * env
                    s = sin(ph) + 0.5 * env * sin(2 * ph) + 0.28 * e2 * sin(3 * ph)
                        + 0.16 * e2 * sin(4 * ph) + 0.08 * e2 * env * sin(5 * ph)
                case .arp:
                    s = 0.65 * table(nv.pointee.phase) * (0.4 + 0.6 * env) + 0.35 * sin(ph)
                }
                s *= env * nv.pointee.atk * nv.pointee.amp
                nL += s * (1 - nv.pointee.pan)
                nR += s * nv.pointee.pan
            }
            // Ping-pong echo on notes
            let dL = echoL.read(echoTime), dR = echoR.read(echoTime)
            echoL.write(Float((nL + nR) * 0.5 + dR * 0.4))
            echoR.write(Float(dL * 0.4))
            nL += dL * 0.4; nR += dR * 0.4

            // Drums
            var drL = 0.0, drR = 0.0
            if kickEnv > 0.0001 {
                kickPitch *= kickPitchDecay
                kickPhase = wrap(kickPhase + (45 + 115 * kickPitch) / sr)
                let kk = sin(2 * .pi * kickPhase) * kickEnv * kickVel * 0.42
                kickEnv *= kickDecay
                drL += kk; drR += kk
            }
            if snareEnv > 0.0001 {
                let n = rng.nextBipolar()
                snareLP += (n - snareLP) * a1500
                snarePhase = wrap(snarePhase + 185 / sr)
                let sn = ((n - snareLP) * 0.6 * snareEnv + sin(2 * .pi * snarePhase) * 0.45 * snareTone)
                    * snareVel * 0.2
                snareEnv *= snareDecay; snareTone *= snareToneDecay
                drL += sn * 0.9; drR += sn
            }
            if hatEnv > 0.0001 {
                let n = rng.nextBipolar()
                hatLP += (n - hatLP) * a7000
                var h = n - hatLP
                if darkHats { hatDark += (h - hatDark) * a5000; h = hatDark * 1.6 }
                h *= hatEnv * hatVel * 0.07
                hatEnv *= hatDecay
                drL += h * 0.8; drR += h * 1.1
            }

            // Vinyl crackle
            if crackle > 0.01 && rng.nextUnit() < crackle * 9 / sr {
                crackleEnv = (0.15 + 0.85 * pow(rng.nextUnit(), 3)) * (rng.nextUnit() < 0.5 ? -1 : 1)
            }
            crackleLP += (crackleEnv - crackleLP) * 0.5
            let crack = (crackleEnv - crackleLP) * 0.06 * crackle
            crackleEnv *= 0.6

            // Dry music bus → reverb (drums get only a small send)
            let dryL = padLP2.0 * padGain + bass + nL
            let dryR = padLP2.1 * padGain + bass + nR
            let revL = reverbL.process(dryL + drL * 0.25), revR = reverbR.process(dryR + drR * 0.25)
            var musL = dryL * (1 - wet * 0.6) + revL * wet * 1.4 + drL
            var musR = dryR * (1 - wet * 0.6) + revR * wet * 1.4 + drR

            // Amplitude modulation (raised-cosine dips at the target rate)
            amPhase += amInc; if amPhase >= 1 { amPhase -= 1 }
            let am = 1 - amDepth * 0.5 * (1 - cos(2 * .pi * amPhase))
            musL = (musL * am + crack) * music
            musR = (musR * am + crack) * music

            // Noise bed
            let wl = rng.nextBipolar(), wr = rng.nextBipolar()
            brownL = (brownL + 0.02 * wl) / 1.02
            brownR = (brownR + 0.02 * wr) / 1.02
            let noL = pinkL.next(wl) * 0.11 * (1 - noiseColor) + brownL * 3.2 * noiseColor
            let noR = pinkR.next(wr) * 0.11 * (1 - noiseColor) + brownR * 3.2 * noiseColor
            noiseLP.0 += (noL - noiseLP.0) * nA
            noiseLP.1 += (noR - noiseLP.1) * nA
            let noiseGain = amb * amb * 0.35

            // Nature (unmodulated)
            var natL = 0.0, natR = 0.0
            natureGen.process(natureTarget, &natL, &natR)

            // Master fade
            if masterGain < gainTarget { masterGain = min(gainTarget, masterGain + gainStep) }
            else if masterGain > gainTarget { masterGain = max(gainTarget, masterGain - gainStep) }
            let g = masterGain * masterGain * vol * vol * 1.6

            left[i] = Float(tanh((musL + noiseLP.0 * noiseGain + natL * natureGain) * g))
            right[i] = Float(tanh((musR + noiseLP.1 * noiseGain + natR * natureGain) * g))
        }
    }

    // MARK: Sequencer

    private func tick() {
        // Switch mode/track right away instead of waiting for the next chord boundary.
        if mode != activeMode || track != activeTrack { step = 0 }
        if step % (16 * tp.chordBars) == 0 { nextChord() }
        let s = step % 16
        if s == 0 { newBar() }

        switch tp.chordInst {
        case .ep: compEP(s)
        case .piano: compPiano(s)
        default: break
        }
        if tp.arp { arpeggiate(s) }

        if s % 2 == 0, let inst = tp.melodyInst {
            var p = pluckDensity * tp.melodyDensity * phraseDensity * (s % 4 == 0 ? 1.0 : 0.55)
            if inst == .bell && s == 0 { p = max(p, pluckDensity * 1.6) }
            if rng.nextUnit() < p { triggerMelody(inst) }
        }

        drums(s)
        if tp.bassPlucked { pluckBass(s) }
        step += 1
    }

    private func newBar() {
        barCount += 1
        if drumsMutedBars > 0 { drumsMutedBars -= 1 }
        else if tp.drums != .none && barCount % 8 == 0 && rng.nextUnit() < 0.3 {
            drumsMutedBars = 2   // occasional breakdown
        }
    }

    private func nextChord() {
        if activeMode != mode || activeTrack != track {
            activeMode = mode
            activeTrack = track
            tp = track.params
            let p = mode.params
            scale = p.scale
            rootMidi = p.rootMidi
            chordDegree = 0
            drumsMutedBars = 0
        } else {
            chordDegree = pickNextDegree()
        }
        if Int.random(in: 0..<4, using: &rng) == 0 {
            phraseDensity = 0.35 + rng.nextUnit()
        }

        for v in 0..<Self.padCount where pads[v].active { pads[v].target = 0 }

        // Chord tones: root, 3rd, 5th plus 7th or 9th, voiced into a mid register.
        let extra = rng.nextUnit() < 0.5 ? 6 : 8
        let low = rootMidi + 2, high = rootMidi + 17
        for k in 0..<4 {
            var m = noteMidi(chordDegree + (k < 3 ? Self.triad[k] : extra))
            while m < low { m += 12 }
            while m >= high { m -= 12 }
            let f = midiToHz(Double(m))
            chord[k] = f
            startPad(f)
        }
        sortAscending(chord, 4)

        bassTarget = midiToHz(Double(rootMidi - 12 + scale[chordDegree]))

        // Melody candidates: chord tones + 9th across two octaves above the pads.
        melodyCount = 0
        for octave in 0..<2 {
            for off in Self.melodyOffsets {
                var m = noteMidi(chordDegree + off)
                while m < rootMidi + 12 { m += 12 }
                m += 12 * octave
                melody[melodyCount] = midiToHz(Double(m))
                melodyCount += 1
            }
        }
        sortAscending(melody, melodyCount)
        melodyIndex = min(melodyIndex, melodyCount - 1)
    }

    private func pickNextDegree() -> Int {
        // Weighted choice among non-diminished diatonic triads, never repeating.
        let weights = Self.degreeWeights
        var total = 0.0
        for d in 0..<7 where d != chordDegree && !isDiminished(d) { total += weights[d] }
        var r = rng.nextUnit() * total
        for d in 0..<7 where d != chordDegree && !isDiminished(d) {
            r -= weights[d]
            if r <= 0 { return d }
        }
        return 0
    }

    private func isDiminished(_ degree: Int) -> Bool {
        noteMidi(degree + 4) - noteMidi(degree) == 6
    }

    // MARK: Parts

    /// Rhodes comping: strummed chord on the downbeat, occasional pushed stabs.
    private func compEP(_ s: Int) {
        let strum = Int(sampleRate * 0.014)
        if s == 0 {
            for k in 0..<4 {
                startNote(.ep, chord[k], amp: 0.05 * (0.8 + 0.2 * rng.nextUnit()),
                          tau: 2.4, delay: k * strum, pan: 0.35 + 0.1 * Double(k))
            }
        } else if (s == 7 || s == 10) && rng.nextUnit() < 0.3 {
            for k in 1..<4 {
                startNote(.ep, chord[k], amp: 0.03, tau: 1.2, delay: (k - 1) * strum, pan: 0.4 + 0.08 * Double(k))
            }
        }
    }

    /// Broken-chord piano figure on 8th notes; sparser in calmer modes.
    private func compPiano(_ s: Int) {
        guard s % 2 == 0 else { return }
        if s == 0 {
            startNote(.piano, chord[0] / 2, amp: 0.07, tau: 3.0, delay: 0, pan: 0.45)
        }
        let p: Double = s == 0 ? 1 : (s % 4 == 0 ? 0.45 + pluckDensity : pluckDensity * 0.9)
        guard rng.nextUnit() < p else { return }
        let idx = Self.pianoPattern[s / 2]
        let f = chord[idx] * (s >= 8 && rng.nextUnit() < 0.3 ? 2 : 1)
        startNote(.piano, f, amp: 0.05 * (0.7 + 0.3 * rng.nextUnit()), tau: 2.6, delay: 0,
                  pan: 0.35 + 0.3 * Double(idx) / 3)
    }

    /// 16th-note arpeggio over the chord, two octaves, up/down.
    private func arpeggiate(_ s: Int) {
        let cycle = arpIndex % 14
        let i = cycle < 8 ? cycle : 14 - cycle
        let f = chord[i % 4] * (i >= 4 ? 2 : 1)
        startNote(.arp, f, amp: s % 4 == 0 ? 0.045 : 0.03, tau: 0.17, delay: 0,
                  pan: arpIndex % 2 == 0 ? 0.35 : 0.65)
        arpIndex += 1
    }

    private func drums(_ s: Int) {
        let kit = tp.drums.rawValue
        guard kit != 0, drumsMutedBars == 0 else { return }
        var kv = DrumPatterns.kick[kit][s]
        var sv = DrumPatterns.snare[kit][s]
        var hv = DrumPatterns.hat[kit][s]
        if tp.drums == .lofi {
            if s == 7 && rng.nextUnit() < 0.25 { kv = 0.5 }      // ghost kick
            if s == 15 && rng.nextUnit() < 0.2 { sv = 0.3 }      // ghost snare
            if hv == 0 && rng.nextUnit() < 0.12 { hv = 0.2 }     // ghost hat
        }
        if kv > 0 {
            kickEnv = 1; kickPitch = 1; kickPhase = 0; kickVel = kv
            if tp.drums == .house { duck = 1 }
        }
        if sv > 0 { snareEnv = 1; snareTone = 1; snareVel = sv }
        if hv > 0 {
            hatEnv = 1; hatVel = hv * (0.85 + 0.15 * rng.nextUnit())
            hatDecay = tp.drums == .house && DrumPatterns.houseOpen[s] ? hatOpen : hatClosed
        }
    }

    private func pluckBass(_ s: Int) {
        let root = midiToHz(Double(rootMidi - 12 + scale[chordDegree]))
        var f = 0.0, vel = 1.0
        switch tp.drums {
        case .lofi:
            if s == 0 { f = root }
            else if s == 10 { f = rng.nextUnit() < 0.5 ? root : root * 1.4983; vel = 0.8 }
            else if s == 7 && rng.nextUnit() < 0.25 { f = root; vel = 0.5 }
        case .house:
            if s % 4 == 2 { f = s == 14 && rng.nextUnit() < 0.4 ? root * 2 : root }
        case .none:
            if s == 0 { f = root }
        }
        guard f > 0 else { return }
        bassTarget = f; bassEnv = 1; bassAtk = 0; bassVel = vel
    }

    private func triggerMelody(_ inst: Instrument) {
        guard melodyCount > 0 else { return }
        let step = Int.random(in: -2...2, using: &rng)
        melodyIndex = max(0, min(melodyCount - 1, melodyIndex + step))
        let amp: Double, tau: Double
        switch inst {
        case .bell: amp = 0.06 + rng.nextUnit() * 0.05; tau = 0.5 + rng.nextUnit() * 1.1
        case .ep: amp = 0.045; tau = 1.6
        case .piano: amp = 0.05 + rng.nextUnit() * 0.02; tau = 2.2
        case .arp: amp = 0.04; tau = 0.3
        }
        startNote(inst, melody[melodyIndex], amp: amp, tau: tau, delay: 0, pan: 0.2 + rng.nextUnit() * 0.6)
    }

    private func startNote(_ kind: Instrument, _ freq: Double, amp: Double, tau: Double, delay: Int, pan: Double) {
        let v = (0..<Self.noteCount).first(where: { !notes[$0].active })
            ?? (0..<Self.noteCount).min(by: { notes[$0].env < notes[$1].env })!
        let atkCoef: Double
        switch kind {
        case .bell: atkCoef = 0.004
        case .ep, .arp: atkCoef = 0.01
        case .piano: atkCoef = 0.02
        }
        notes[v] = Note(kind: kind, freq: freq, phase: 0, env: 1, decay: exp(-1 / (tau * sampleRate)),
                        atk: 0, atkCoef: atkCoef * 48000 / sampleRate, amp: amp, pan: pan,
                        delay: delay, active: true)
    }

    private func startPad(_ freq: Double) {
        let v = (0..<Self.padCount).first(where: { !pads[$0].active })
            ?? (0..<Self.padCount).min(by: { pads[$0].env < pads[$1].env })!
        pads[v] = Pad(freq: freq, p1: rng.nextUnit(), p2: rng.nextUnit(), p3: rng.nextUnit(),
                      env: 0, target: 1, active: true)
    }

    // MARK: Helpers

    private func noteMidi(_ idx: Int) -> Int { rootMidi + scale[idx % 7] + 12 * (idx / 7) }

    @inline(__always) private func table(_ phase: Double) -> Double {
        let x = phase * Double(Self.tableSize)
        let i = Int(x), f = Float(x - Double(i))
        return Double(warmTable[i] + (warmTable[i + 1] - warmTable[i]) * f)
    }
}

// MARK: - DSP building blocks

struct Pad {
    var freq = 0.0, p1 = 0.0, p2 = 0.0, p3 = 0.0, env = 0.0, target = 0.0
    var active = false
}

struct Note {
    var kind: Instrument = .bell
    var freq = 0.0, phase = 0.0, env = 0.0, decay = 0.0, atk = 0.0, atkCoef = 0.0, amp = 0.0, pan = 0.5
    var delay = 0
    var active = false
}

/// Paul Kellet's economy pink-noise filter.
struct Pink {
    var b0 = 0.0, b1 = 0.0, b2 = 0.0
    mutating func next(_ w: Double) -> Double {
        b0 = 0.99765 * b0 + w * 0.0990460
        b1 = 0.96300 * b1 + w * 0.2965164
        b2 = 0.57000 * b2 + w * 1.0526913
        return b0 + b1 + b2 + w * 0.1848
    }
}

/// Fractional delay line with linear interpolation.
final class DelayLine {
    private let buf: UnsafeMutablePointer<Float>
    private let size: Int
    private var pos = 0

    init(capacity: Int) {
        size = capacity
        buf = .allocate(capacity: capacity)
        buf.initialize(repeating: 0, count: capacity)
    }
    deinit { buf.deallocate() }

    @inline(__always) func read(_ delay: Double) -> Double {
        let d = min(Double(size - 2), max(1, delay))
        var r = Double(pos) - d
        if r < 0 { r += Double(size) }
        let i = Int(r), f = Float(r - Double(i))
        let j = i + 1 == size ? 0 : i + 1
        return Double(buf[i] + (buf[j] - buf[i]) * f)
    }

    @inline(__always) func write(_ x: Float) {
        buf[pos] = x
        pos += 1; if pos == size { pos = 0 }
    }
}

/// Mono Freeverb (6 damped combs + 3 allpasses). Two instances with different
/// spreads give a decorrelated stereo tail.
final class Freeverb {
    private struct Comb { var buf: UnsafeMutablePointer<Float>; var size: Int; var pos = 0; var store: Float = 0 }
    private struct Allpass { var buf: UnsafeMutablePointer<Float>; var size: Int; var pos = 0 }
    private var combs: UnsafeMutablePointer<Comb>
    private var aps: UnsafeMutablePointer<Allpass>
    private let feedback: Float = 0.88, damp: Float = 0.35

    init(sampleRate: Double, spread: Int) {
        let scale = sampleRate / 44100
        let combLens = [1116, 1188, 1277, 1356, 1422, 1491]
        let apLens = [556, 441, 341]
        combs = .allocate(capacity: combLens.count)
        aps = .allocate(capacity: apLens.count)
        for (i, l) in combLens.enumerated() {
            let n = Int(Double(l + spread) * scale)
            let b = UnsafeMutablePointer<Float>.allocate(capacity: n); b.initialize(repeating: 0, count: n)
            (combs + i).initialize(to: Comb(buf: b, size: n))
        }
        for (i, l) in apLens.enumerated() {
            let n = Int(Double(l + spread) * scale)
            let b = UnsafeMutablePointer<Float>.allocate(capacity: n); b.initialize(repeating: 0, count: n)
            (aps + i).initialize(to: Allpass(buf: b, size: n))
        }
    }

    deinit {
        for i in 0..<6 { combs[i].buf.deallocate() }
        for i in 0..<3 { aps[i].buf.deallocate() }
        combs.deallocate(); aps.deallocate()
    }

    @inline(__always) func process(_ input: Double) -> Double {
        let x = Float(input) * 0.02
        var out: Float = 0
        for i in 0..<6 {
            let c = combs + i
            let y = c.pointee.buf[c.pointee.pos]
            c.pointee.store = y * (1 - damp) + c.pointee.store * damp
            c.pointee.buf[c.pointee.pos] = x + c.pointee.store * feedback
            c.pointee.pos += 1; if c.pointee.pos == c.pointee.size { c.pointee.pos = 0 }
            out += y
        }
        for i in 0..<3 {
            let a = aps + i
            let b = a.pointee.buf[a.pointee.pos]
            a.pointee.buf[a.pointee.pos] = out + b * 0.5
            out = b - out
            a.pointee.pos += 1; if a.pointee.pos == a.pointee.size { a.pointee.pos = 0 }
        }
        return Double(out)
    }
}

/// Small, allocation-free PRNG for the audio thread.
struct XorShift: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func nextBipolar() -> Double { nextUnit() * 2 - 1 }
}

private func sortAscending(_ p: UnsafeMutablePointer<Double>, _ n: Int) {
    guard n > 1 else { return }
    for i in 1..<n {
        let x = p[i]; var j = i - 1
        while j >= 0 && p[j] > x { p[j + 1] = p[j]; j -= 1 }
        p[j + 1] = x
    }
}

@inline(__always) private func wrap(_ x: Double) -> Double { x >= 1 ? x - 1 : x }
@inline(__always) private func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
@inline(__always) private func midiToHz(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }
