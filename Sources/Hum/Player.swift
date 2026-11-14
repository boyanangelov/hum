import AVFoundation
import Combine
import ServiceManagement

@MainActor
final class Player: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published var mode: Mode { didSet { synth.mode = mode; save() } }
    @Published var track: Track { didSet { synth.track = track; save() } }
    @Published var nature: NatureSound { didSet { synth.nature = nature; save() } }
    @Published var volume: Double { didSet { synth.volume = volume; save() } }
    @Published var musicLevel: Double { didSet { synth.musicLevel = musicLevel; save() } }
    @Published var natureLevel: Double { didSet { synth.natureLevel = natureLevel; save() } }
    @Published var intensity: Double { didSet { synth.intensity = intensity; save() } }
    @Published var ambience: Double { didSet { synth.ambience = ambience; save() } }
    @Published private(set) var timerEnd: Date?
    @Published private(set) var now = Date()
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Hum: launch-at-login change failed: \(error)")
            }
        }
    }

    private let engine = AVAudioEngine()
    private let synth: Synth
    private var ticker: Timer?
    private var stopWork: DispatchWorkItem?
    private let defaults = UserDefaults.standard

    init() {
        let d = UserDefaults.standard
        mode = Mode(rawValue: d.integer(forKey: "mode")) ?? .focus
        track = Track(rawValue: d.integer(forKey: "track")) ?? .ambient
        nature = NatureSound(rawValue: d.integer(forKey: "nature")) ?? .none
        volume = d.object(forKey: "volume") as? Double ?? 0.7
        musicLevel = d.object(forKey: "musicLevel") as? Double ?? 1.0
        natureLevel = d.object(forKey: "natureLevel") as? Double ?? 0.7
        intensity = d.object(forKey: "intensity") as? Double ?? 0.7
        ambience = d.object(forKey: "ambience") as? Double ?? 0.1

        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sr = rate > 0 ? rate : 48000
        synth = Synth(sampleRate: sr)
        synth.mode = mode
        synth.track = track
        synth.nature = nature
        synth.volume = volume
        synth.musicLevel = musicLevel
        synth.natureLevel = natureLevel
        synth.intensity = intensity
        synth.ambience = ambience

        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let s = synth
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard buffers.count >= 2,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            s.render(frames: Int(frameCount), left: l, right: r)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)

        // Restart after output device changes (headphones plugged in, etc.).
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                try? self.engine.start()
            }
        }

        // Self-tests for development: HUM_SELFTEST=audio (silent engine check) or =login.
        switch ProcessInfo.processInfo.environment["HUM_SELFTEST"] {
        case "audio":
            synth.volume = 0
            play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                print("SELFTEST audio engineRunning=\(engine.isRunning) rendering=\(synth.isAudible) sr=\(synth.sampleRate)")
                exit(synth.isAudible ? 0 : 1)
            }
        case "login":
            let service = SMAppService.mainApp
            do { try service.register() } catch { print("SELFTEST login register error: \(error)") }
            print("SELFTEST login after register: \(service.status.rawValue)")
            do { try service.unregister() } catch { print("SELFTEST login unregister error: \(error)") }
            print("SELFTEST login after unregister: \(service.status.rawValue)")
            exit(0)
        default:
            break
        }
    }

    // MARK: Transport

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        stopWork?.cancel()
        synth.fadeSeconds = 2
        synth.isPlaying = true
        if !engine.isRunning {
            do { try engine.start() } catch { NSLog("Hum: engine start failed: \(error)"); return }
        }
        isPlaying = true
    }

    func pause(fade: Double = 1.5) {
        synth.fadeSeconds = fade
        synth.isPlaying = false
        isPlaying = false
        cancelTimer()
        // Stop the engine once the fade is done so we use no CPU while idle.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPlaying else { return }
            self.engine.stop()
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + fade + 0.5, execute: work)
    }

    // MARK: Timer

    func startTimer(minutes: Int) {
        now = Date()
        timerEnd = now.addingTimeInterval(TimeInterval(minutes * 60))
        if !isPlaying { play() }
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func cancelTimer() {
        ticker?.invalidate(); ticker = nil
        timerEnd = nil
    }

    private func tick() {
        now = Date()
        if let end = timerEnd, now >= end {
            pause(fade: mode == .sleep ? 30 : 8)   // gentle fade-out
        }
    }

    var remainingText: String? {
        guard let end = timerEnd else { return nil }
        let s = max(0, Int(end.timeIntervalSince(now)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func save() {
        defaults.set(mode.rawValue, forKey: "mode")
        defaults.set(track.rawValue, forKey: "track")
        defaults.set(nature.rawValue, forKey: "nature")
        defaults.set(volume, forKey: "volume")
        defaults.set(musicLevel, forKey: "musicLevel")
        defaults.set(natureLevel, forKey: "natureLevel")
        defaults.set(intensity, forKey: "intensity")
        defaults.set(ambience, forKey: "ambience")
    }
}
