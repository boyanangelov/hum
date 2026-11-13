import Foundation

/// A listening mode. Each mode pairs a musical character with an amplitude-modulation
/// rate in a different EEG band (the "neural phase locking" approach described in
/// Brain.fm's published research, e.g. Woods et al., Communications Biology 2024).
public enum Mode: Int, CaseIterable, Identifiable, Sendable {
    case focus, relax, meditate, sleep

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .focus: "Focus"
        case .relax: "Relax"
        case .meditate: "Meditate"
        case .sleep: "Sleep"
        }
    }

    public var symbol: String {
        switch self {
        case .focus: "brain.head.profile"
        case .relax: "leaf"
        case .meditate: "sparkles"
        case .sleep: "moon.zzz"
        }
    }

    public var band: String {
        switch self {
        case .focus: "Beta · 16 Hz modulation"
        case .relax: "Alpha · 10 Hz modulation"
        case .meditate: "Theta · 6 Hz modulation"
        case .sleep: "Delta · 2 Hz modulation"
        }
    }

    var params: ModeParams { ModeParams.table[rawValue] }

    fileprivate var makeParams: ModeParams {
        switch self {
        case .focus:
            ModeParams(amRate: 16, amDepth: 0.6, bpm: 80, rootMidi: 50,
                       scale: [0, 2, 3, 5, 7, 9, 10],      // D dorian
                       pluckDensity: 0.34, brightness: 0.65, reverbMix: 0.28,
                       noiseColor: 0.3, keyName: "D dorian")
        case .relax:
            ModeParams(amRate: 10, amDepth: 0.45, bpm: 64, rootMidi: 53,
                       scale: [0, 2, 4, 6, 7, 9, 11],      // F lydian
                       pluckDensity: 0.22, brightness: 0.5, reverbMix: 0.38,
                       noiseColor: 0.5, keyName: "F lydian")
        case .meditate:
            ModeParams(amRate: 6, amDepth: 0.4, bpm: 54, rootMidi: 48,
                       scale: [0, 2, 4, 5, 7, 9, 10],      // C mixolydian
                       pluckDensity: 0.14, brightness: 0.4, reverbMix: 0.45,
                       noiseColor: 0.7, keyName: "C mixolydian")
        case .sleep:
            ModeParams(amRate: 2, amDepth: 0.35, bpm: 46, rootMidi: 45,
                       scale: [0, 2, 3, 5, 7, 8, 10],      // A aeolian
                       pluckDensity: 0.06, brightness: 0.22, reverbMix: 0.5,
                       noiseColor: 0.95, keyName: "A aeolian")
        }
    }
}

struct ModeParams {
    let amRate: Double        // Hz
    let amDepth: Double       // 0...1 at full intensity
    let bpm: Double
    let rootMidi: Int
    let scale: [Int]          // 7 semitone offsets
    let pluckDensity: Double  // probability per 8th note
    let brightness: Double    // 0...1 → pad filter cutoff
    let reverbMix: Double
    let noiseColor: Double    // 0 = pink, 1 = brown
    let keyName: String
}

extension ModeParams {
    /// Built once so the audio thread never allocates when reading params.
    static let table: [ModeParams] = Mode.allCases.map(\.makeParams)
}
