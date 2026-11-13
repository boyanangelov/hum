import SwiftUI

@main
struct DriftApp: App {
    @StateObject private var player = Player()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(player)
        } label: {
            Image(systemName: player.isPlaying ? player.mode.symbol : "waveform")
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuView: View {
    @EnvironmentObject var player: Player

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            section("Mode", detail: player.mode.band)
            HStack(spacing: 6) {
                ForEach(Mode.allCases) { m in
                    Chip(symbol: m.symbol, title: m.title, selected: player.mode == m) { player.mode = m }
                }
            }

            section("Track", detail: player.track.subtitle)
            HStack(spacing: 6) {
                ForEach(Track.allCases) { t in
                    Chip(symbol: t.symbol, title: t.title, selected: player.track == t) { player.track = t }
                }
            }

            section("Nature", detail: player.nature.title)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                ForEach(NatureSound.allCases) { n in
                    Chip(symbol: n.symbol, title: nil, selected: player.nature == n) { player.nature = n }
                        .help(n.title)
                }
            }

            Divider()

            VStack(spacing: 6) {
                slider("Volume", "speaker.wave.2", $player.volume)
                slider("Music", "music.note", $player.musicLevel)
                slider("Nature", "leaf", $player.natureLevel)
                slider("Noise", "wind", $player.ambience)
                slider("Modulation", "waveform.path.ecg", $player.intensity)
            }

            Divider()

            HStack {
                Image(systemName: "timer").foregroundStyle(.secondary).frame(width: 18)
                Text("Session").font(.callout)
                Spacer()
                Menu(player.timerEnd == nil ? "Off" : "Running") {
                    ForEach([25, 50, 90, 120], id: \.self) { m in
                        Button("\(m) minutes") { player.startTimer(minutes: m) }
                    }
                    if player.timerEnd != nil {
                        Divider()
                        Button("Cancel timer") { player.cancelTimer() }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            HStack {
                Toggle("Launch at login", isOn: $player.launchAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                    .font(.caption)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: player.toggle) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

            VStack(alignment: .leading, spacing: 2) {
                Text("\(player.mode.title) · \(player.track.title)").font(.headline)
                Text(player.nature == .none ? "No nature sounds" : "with \(player.nature.title)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let remaining = player.remainingText {
                Label(remaining, systemImage: "timer")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.bottom, -6)
    }

    private func slider(_ title: String, _ icon: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            Text(title).font(.callout).frame(width: 82, alignment: .leading)
            Slider(value: value, in: 0...1).controlSize(.small)
        }
    }
}

struct Chip: View {
    let symbol: String
    let title: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 14))
                if let title { Text(title).font(.caption2).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, minHeight: title == nil ? 34 : 44)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
