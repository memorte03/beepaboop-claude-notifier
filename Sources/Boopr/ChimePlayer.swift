import Foundation
import AVFoundation

/// Synthesizes short chime notifications.
/// Same timbre (sine + light harmonics, fast attack, exponential decay) so all
/// kinds feel like a single sound family. The difference between kinds is the
/// note(s) played — not the instrument.
@MainActor
final class ChimePlayer: ObservableObject {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 44_100
    private var graphBuilt = false
    private var configObserver: NSObjectProtocol?

    @Published var muted: Bool = UserDefaults.standard.bool(forKey: "chimeMuted") {
        didSet { UserDefaults.standard.set(muted, forKey: "chimeMuted") }
    }

    /// 0…1 multiplier on the synthesized amplitude.
    @Published var volume: Double = min(max(UserDefaults.standard.object(forKey: "chimeVolume") as? Double ?? 1.0, 0), 1) {
        didSet {
            let clamped = min(max(volume, 0), 1)
            if clamped != volume { volume = clamped; return }
            UserDefaults.standard.set(volume, forKey: "chimeVolume")
        }
    }

    struct Note {
        let freq: Double   // 0 = rest
        let duration: TimeInterval
        let amp: Double    // 0…1 — per-note attenuation
    }

    init() {
        // The audio graph is built lazily on first play — NOT here. init runs at
        // login (launchd), when the output device often isn't ready yet; wiring
        // the engine then bakes the mixer→output leg against a phantom device, so
        // start() later succeeds silently but no audio routes. Building on first
        // play guarantees the real device is present regardless of launch context.
        //
        // A configuration change (device appears/disappears, output switched)
        // stops the engine and can invalidate the graph — rebuild on the next play.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.player.stop()
                self.engine.stop()
                self.graphBuilt = false
            }
        }
    }

    // No deinit cleanup needed: ChimePlayer lives for the app's lifetime and
    // the observer closure captures self weakly.

    func play(for kind: NotifyKind) {
        guard !muted else { return }
        guard ensureRunning() else { return }
        let seq = sequence(for: kind)
        guard let buf = synthesize(notes: seq) else { return }
        player.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    /// Builds the graph against the current output device (if needed) and starts
    /// the engine. Returns whether the engine is running.
    private func ensureRunning() -> Bool {
        if !graphBuilt {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
            else { return false }
            if player.engine == nil { engine.attach(player) }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            graphBuilt = true
        }
        if engine.isRunning { return true }
        do {
            engine.prepare()
            try engine.start()
            return true
        } catch {
            NSLog("audio engine start failed: \(error)")
            graphBuilt = false   // force a clean rebuild next time
            return false
        }
    }

    // MARK: per-kind sequences

    private func sequence(for kind: NotifyKind) -> [Note] {
        // All sequences live in a pentatonic-ish neighbourhood (E5, G5, A5, C5,
        // D5, A4, F4) so they sit in the same musical family.
        switch kind {
        case .stop:
            // gentle ascending two-note "done"
            return [
                .init(freq: 659.25, duration: 0.14, amp: 1.0),   // E5
                .init(freq: 783.99, duration: 0.26, amp: 1.0)    // G5
            ]
        case .idle:
            // single soft mid note
            return [.init(freq: 587.33, duration: 0.32, amp: 0.85)]  // D5
        case .permission:
            // double-tap, attention-grabbing but not jarring
            return [
                .init(freq: 880.00, duration: 0.10, amp: 1.0),   // A5
                .init(freq: 0,      duration: 0.06, amp: 0),
                .init(freq: 880.00, duration: 0.18, amp: 1.0)    // A5
            ]
        case .ask:
            // rising "questioning" lilt — C5 → G5, softer than permission
            return [
                .init(freq: 523.25, duration: 0.12, amp: 0.9),   // C5
                .init(freq: 783.99, duration: 0.22, amp: 0.9)    // G5
            ]
        case .info:
            // short single E5 blip
            return [.init(freq: 659.25, duration: 0.20, amp: 0.7)]
        case .error:
            // descending two-note minor — A4 → F4
            return [
                .init(freq: 440.00, duration: 0.12, amp: 1.0),   // A4
                .init(freq: 349.23, duration: 0.28, amp: 1.0)    // F4
            ]
        }
    }

    // MARK: synthesis

    private func synthesize(notes: [Note]) -> AVAudioPCMBuffer? {
        let total = notes.reduce(0) { $0 + $1.duration } + 0.06
        let frameCount = AVAudioFrameCount(total * sampleRate)
        guard frameCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        buf.frameLength = frameCount
        guard let data = buf.floatChannelData?[0] else { return nil }

        let capacity = Int(frameCount)
        var idx = 0
        for note in notes {
            // Clamp to the buffer: per-note floor-rounding of durations can let
            // the running index drift past frameCount, which would write OOB.
            let n = min(Int(note.duration * sampleRate), capacity - idx)
            if n <= 0 { break }
            for i in 0..<n {
                let t = Double(i) / sampleRate
                let env = envelope(t: t, duration: note.duration)
                let sample: Double
                if note.freq > 0 {
                    let f = note.freq
                    let h1 = sin(2 * .pi * f       * t)
                    let h2 = sin(2 * .pi * f * 2.0 * t) * 0.25
                    let h3 = sin(2 * .pi * f * 3.0 * t) * 0.08
                    sample = (h1 + h2 + h3) * env * note.amp * 0.22 * volume
                } else {
                    sample = 0
                }
                data[idx + i] = Float(sample)
            }
            idx += n
        }
        // tail silence
        let tail = min(Int(0.06 * sampleRate), Int(frameCount) - idx)
        for i in 0..<max(0, tail) { data[idx + i] = 0 }
        return buf
    }

    private func envelope(t: Double, duration: Double) -> Double {
        let attack = 0.006
        let attackEnv = t < attack ? t / attack : 1.0
        // longer decay tau on longer notes
        let tau = max(0.05, duration * 0.45)
        let decayEnv = exp(-t / tau)
        return attackEnv * decayEnv
    }
}
