
import Foundation

// Usage: hum-render <mode 0-3> <track 0-4> <nature 0-10> <seconds> <out.wav>
// Env: VOL, MUSIC, NATURE, NOISE (0...1). SCHEDULE="t play;t mode N;t track N;t nature N;..."
// replays setting changes at the given times in seconds (starts paused if it has a play event). Renders offline to 16-bit WAV and prints
// levels and render speed.
let args = CommandLine.arguments
func arg(_ i: Int, _ d: String) -> String { args.count > i ? args[i] : d }
func env(_ k: String, _ d: Double) -> Double { Double(ProcessInfo.processInfo.environment[k] ?? "") ?? d }
let mode = Mode(rawValue: Int(arg(1, "0")) ?? 0) ?? .focus
let track = Track(rawValue: Int(arg(2, "0")) ?? 0) ?? .ambient
let nature = NatureSound(rawValue: Int(arg(3, "0")) ?? 0) ?? .none
let seconds = Double(arg(4, "30")) ?? 30
let outPath = arg(5, "hum.wav")

let sr = 48000.0
let synth = Synth(sampleRate: sr)
synth.mode = mode
synth.track = track
synth.nature = nature
synth.musicLevel = env("MUSIC", 1)
synth.natureLevel = env("NATURE", 0.6)
synth.isPlaying = true
synth.fadeSeconds = 0.5
synth.ambience = env("NOISE", 0.15)
synth.volume = env("VOL", 0.7)

var schedule: [(Double, String, Int)] = (ProcessInfo.processInfo.environment["SCHEDULE"] ?? "")
    .split(separator: ";").compactMap { e in
        let p = e.split(separator: " ")
        guard p.count >= 2, let t = Double(p[0]) else { return nil }
        return (t, String(p[1]), p.count > 2 ? Int(p[2]) ?? 0 : 0)
    }
if schedule.contains(where: { $0.1 == "play" }) { synth.isPlaying = false; synth.fadeSeconds = 2 }

let total = Int(sr * seconds), block = 256
let l = UnsafeMutablePointer<Float>.allocate(capacity: block)
let r = UnsafeMutablePointer<Float>.allocate(capacity: block)
var pcm = Data(capacity: total * 4)
var peak: Float = 0, sumSq = 0.0
let t0 = Date()
var done = 0
while done < total {
    let now = Double(done) / sr
    while let e = schedule.first, e.0 <= now {
        schedule.removeFirst()
        switch e.1 {
        case "play": synth.isPlaying = true
        case "mode": synth.mode = Mode(rawValue: e.2) ?? .focus
        case "track": synth.track = Track(rawValue: e.2) ?? .ambient
        case "nature": synth.nature = NatureSound(rawValue: e.2) ?? .none
        default: break
        }
    }
    let n = min(block, total - done)
    synth.render(frames: n, left: l, right: r)
    for i in 0..<n {
        for x in [l[i], r[i]] {
            peak = max(peak, abs(x)); sumSq += Double(x * x)
            var v = Int16(max(-1, min(1, x)) * 32767).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
    }
    done += n
}
let elapsed = Date().timeIntervalSince(t0)

var wav = Data()
func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
wav.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count))
wav.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(2)
u32(UInt32(sr)); u32(UInt32(sr) * 4); u16(4); u16(16)
wav.append("data".data(using: .ascii)!); u32(UInt32(pcm.count)); wav.append(pcm)
try! wav.write(to: URL(fileURLWithPath: outPath))

let rms = sqrt(sumSq / Double(total * 2))
print(String(format: "%@/%@/%@: peak %.3f (%.1f dBFS), rms %.1f dBFS, %.0fx realtime → %@",
             mode.title, track.title, nature.title, peak, 20 * log10(Double(peak)), 20 * log10(rms), seconds / elapsed, outPath))
