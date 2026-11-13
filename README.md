# Drift

A macOS menu bar app that generates endless, non-repeating ambient music in real time,
with rhythmic amplitude modulation tuned to brainwave bands, the technique Brain.fm's
published research focuses on.

| Mode     | Modulation      | Music                                   |
|----------|-----------------|-----------------------------------------|
| Focus    | 16 Hz (beta)    | D dorian, 80 bpm, brighter, more notes  |
| Relax    | 10 Hz (alpha)   | F lydian, 64 bpm                        |
| Meditate | 6 Hz (theta)    | C mixolydian, 54 bpm, spacious          |
| Sleep    | 2 Hz (delta)    | A aeolian, 46 bpm, dark, brown noise    |

Each mode can be combined with a **track** (musical style) and a **nature scene**:

| Track   | Sound                                                         |
|---------|---------------------------------------------------------------|
| Ambient | Warm detuned pads, glassy bell melodies                       |
| Lo-fi   | FM Rhodes chords, swung boom-bap drums, plucked bass, vinyl crackle, tape wobble |
| Piano   | Sparse broken-chord piano figures over a soft pad             |
| Pulse   | 16th-note arpeggios, four-on-the-floor kick, sidechain pumping |
| Drone   | Slow 4-bar chords, deep bass, almost no melody                |

Nature scenes: Rain, Rainy Street (cars hissing past with Doppler shift), Ocean Surf,
Seaside (lapping waves and gulls), Stream, Forest (birdsong), Wind, Fireplace, Night
(crickets), Old Train (rail-joint clickety-clack, rumble, distant whistle). Every
sound is synthesized; there are no recordings. Nature sounds are not modulated.

Controls: volume, separate music, nature and noise levels, neural-modulation intensity (0 = plain ambient music),
ambience (noise bed), session timer (25/50/90/120 min with a gentle fade-out;
30 s fade in Sleep), launch at login. Space toggles play/pause while the menu is open.

## Build

    ./build.sh            # needs only Xcode Command Line Tools
    open build/Drift.app
    cp -R build/Drift.app /Applications/   # optional; needed for launch-at-login

Offline render (for auditioning or checking levels):

    swiftc -O Sources/DriftCore/*.swift Sources/DriftRender/main.swift -o .build/drift-render
    # mode 0-3, track 0-4, nature 0-10, seconds, output (env: VOL MUSIC NATURE NOISE)
    .build/drift-render 0 1 2 60 lofi-rainy-street.wav

## How it works

`Sources/DriftCore/Synth.swift` is a sample-level synthesizer running inside an
`AVAudioSourceNode`. It uses no samples and makes no allocations on the audio thread.

- **Harmony:** Markov chord progression over the mode's scale. Diminished triads are
  skipped and the same chord never repeats. Chords change every 2 bars as 4-voice
  detuned wavetable pads through a slowly sweeping low-pass filter.
- **Bass:** a sine that glides to each chord root.
- **Melody:** sparse plucks on a random walk over chord tones with ping-pong echo.
  Density varies by phrase.
- **Space:** Freeverb-style reverb with 6 combs and 3 allpasses per channel.
- **Noise bed:** pink/brown noise blend.
- **Modulation:** raised-cosine amplitude modulation applied to the whole music bus
  after the reverb, so the reverb doesn't smear it.

## A note on "scientifically proven"

Brain.fm has peer-reviewed work, e.g. Woods et al., *Communications Biology* (2024),
which found that music with ~16 Hz amplitude modulation improved sustained attention in
some listeners, especially people with ADHD symptoms. Drift uses the same basic idea,
but it is an independent approximation. Its specific sounds and parameters have not
been tested in any study. Treat it as a pleasant tool, not a medical one.
