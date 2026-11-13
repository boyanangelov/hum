import Foundation

/// A musical style. The selected `Mode` still decides key, base tempo and modulation
/// rate; the track decides instrumentation, rhythm and feel.
public enum Track: Int, CaseIterable, Identifiable, Sendable {
    case ambient, lofi, piano, pulse, drone

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .ambient: "Ambient"
        case .lofi: "Lo-fi"
        case .piano: "Piano"
        case .pulse: "Pulse"
        case .drone: "Drone"
        }
    }

    public var subtitle: String {
        switch self {
        case .ambient: "Warm pads, glassy bells"
        case .lofi: "Rhodes, swung beats, vinyl"
        case .piano: "Sparse felt-piano patterns"
        case .pulse: "Arpeggios, steady kick"
        case .drone: "Slow, deep, beatless"
        }
    }

    public var symbol: String {
        switch self {
        case .ambient: "cloud"
        case .lofi: "headphones"
        case .piano: "pianokeys"
        case .pulse: "metronome"
        case .drone: "infinity"
        }
    }

    var params: TrackParams { TrackParams.table[rawValue] }

    fileprivate var makeParams: TrackParams {
        switch self {
        case .ambient:
            TrackParams(padLevel: 1, chordInst: nil, melodyInst: .bell, melodyDensity: 1,
                        drums: .none, arp: false, bassPlucked: false, bassLevel: 1,
                        swing: 0, tempoScale: 1, minBpm: 40, maxBpm: 100, crackle: 0,
                        chordBars: 2, brightness: 1, wobble: 0, reverbScale: 1, gain: 1.0)
        case .lofi:
            TrackParams(padLevel: 0.3, chordInst: .ep, melodyInst: .ep, melodyDensity: 0.55,
                        drums: .lofi, arp: false, bassPlucked: true, bassLevel: 1.3,
                        swing: 0.16, tempoScale: 1, minBpm: 62, maxBpm: 86, crackle: 1,
                        chordBars: 1, brightness: 0.8, wobble: 0.0035, reverbScale: 0.6, gain: 1.15)
        case .piano:
            TrackParams(padLevel: 0.22, chordInst: .piano, melodyInst: .piano, melodyDensity: 0.7,
                        drums: .none, arp: false, bassPlucked: false, bassLevel: 0.45,
                        swing: 0, tempoScale: 0.9, minBpm: 42, maxBpm: 84, crackle: 0,
                        chordBars: 2, brightness: 0.9, wobble: 0, reverbScale: 1.2, gain: 2.0)
        case .pulse:
            TrackParams(padLevel: 0.6, chordInst: nil, melodyInst: .bell, melodyDensity: 0.35,
                        drums: .house, arp: true, bassPlucked: true, bassLevel: 1.1,
                        swing: 0, tempoScale: 1.45, minBpm: 96, maxBpm: 122, crackle: 0,
                        chordBars: 2, brightness: 1.15, wobble: 0, reverbScale: 0.8, gain: 0.65)
        case .drone:
            TrackParams(padLevel: 1.2, chordInst: nil, melodyInst: .bell, melodyDensity: 0.25,
                        drums: .none, arp: false, bassPlucked: false, bassLevel: 1.3,
                        swing: 0, tempoScale: 0.7, minBpm: 30, maxBpm: 70, crackle: 0,
                        chordBars: 4, brightness: 0.7, wobble: 0, reverbScale: 1.4, gain: 0.85)
        }
    }
}

enum Instrument: Int { case bell, ep, piano, arp }
enum DrumKit: Int { case none, lofi, house }

struct TrackParams {
    let padLevel: Double
    let chordInst: Instrument?
    let melodyInst: Instrument?
    let melodyDensity: Double
    let drums: DrumKit
    let arp: Bool
    let bassPlucked: Bool
    let bassLevel: Double
    let swing: Double          // fraction of a 16th the even steps are lengthened by
    let tempoScale: Double
    let minBpm: Double
    let maxBpm: Double
    let crackle: Double
    let chordBars: Int
    let brightness: Double
    let wobble: Double         // tape wow depth (pitch ratio)
    let reverbScale: Double
    var gain: Double = 1     // loudness normalisation

    static let table: [TrackParams] = Track.allCases.map(\.makeParams)
}

/// 16-step drum patterns (velocity per step). Index by DrumKit raw value.
enum DrumPatterns {
    static let kick: [[Double]] = [
        Array(repeating: 0, count: 16),
        [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.8, 0, 0, 0, 0, 0],
        [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0],
    ]
    static let snare: [[Double]] = [
        Array(repeating: 0, count: 16),
        [0, 0, 0, 0, 0.9, 0, 0, 0, 0, 0, 0, 0, 0.9, 0, 0, 0],
        [0, 0, 0, 0, 0.55, 0, 0, 0, 0, 0, 0, 0, 0.55, 0, 0, 0],
    ]
    static let hat: [[Double]] = [
        Array(repeating: 0, count: 16),
        [0.7, 0, 0.35, 0, 0.7, 0, 0.35, 0, 0.7, 0, 0.35, 0, 0.7, 0, 0.35, 0],
        [0.2, 0.25, 0.7, 0.25, 0.2, 0.25, 0.7, 0.25, 0.2, 0.25, 0.7, 0.25, 0.2, 0.25, 0.7, 0.3],
    ]
    /// Steps where the house hat is open (longer decay).
    static let houseOpen: [Bool] = (0..<16).map { $0 % 4 == 2 }
}
