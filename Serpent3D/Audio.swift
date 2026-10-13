import AVFoundation
#if os(iOS)
import UIKit
#endif

/// Fully synthesized retro "phone buzzer" sound effects and an original chiptune loop.
final class Audio {
    static let shared = Audio()
    enum Sfx: CaseIterable { case eat, special, speed, slow, crash, gameOver, crush, gate, win, bite, stun, ready }

    var soundOn = true
    var musicOn = true { didSet { musicOn ? startMusic() : queue.async { self.music.stop() } } }

    private let engine = AVAudioEngine()
    private let players = (0..<6).map { _ in AVAudioPlayerNode() }
    private let music = AVAudioPlayerNode()
    private var next = 0
    private var buffers: [Sfx: AVAudioPCMBuffer] = [:]
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private let queue = DispatchQueue(label: "audio")
    private var sr: Double { format.sampleRate }

    private init() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        for p in players + [music] { engine.attach(p); engine.connect(p, to: engine.mainMixerNode, format: format) }
        music.volume = 0.32
        buffers = [
            .eat: notes("C6:1 G6:1", step: 0.045, vol: 0.22),
            .special: notes("C6:1 E6:1 G6:1 C7:3", step: 0.035, vol: 0.22),
            .speed: sweep(from: 300, to: 2400, len: 0.22, vol: 0.18),
            .slow: sweep(from: 1600, to: 180, len: 0.35, vol: 0.18),
            .crash: mix(sweep(from: 900, to: 60, len: 0.35, vol: 0.2), noise(0.35, vol: 0.35)),
            .gameOver: notes("G5:2 E5:2 C5:2 G4:6", step: 0.11, vol: 0.22),
            .crush: mix(notes("C3:1 G2:2", step: 0.06, vol: 0.25), noise(0.18, vol: 0.3)),
            .gate: notes("C5:1 E5:1 G5:1 C6:1 - G5:1 C6:4", step: 0.08, vol: 0.22),
            .win: notes("G5:1 C6:1 E6:1 G6:2 E6:1 G6:4", step: 0.07, vol: 0.22),
            .bite: notes("A3:1 E3:2", step: 0.05, vol: 0.28),
            .stun: wobble(len: 0.5, vol: 0.2),
            .ready: notes("C6:1 - C6:1 - G6:3", step: 0.06, vol: 0.18),
        ]
        try? engine.start()
    }

    func play(_ s: Sfx) {
        guard soundOn, let b = buffers[s] else { return }
        queue.async {
            if !self.engine.isRunning { try? self.engine.start() }
            let p = self.players[self.next]; self.next = (self.next + 1) % self.players.count
            p.stop(); p.scheduleBuffer(b); p.play()
        }
    }

    func startMusic() {
        guard musicOn else { return }
        queue.async {
            if !self.engine.isRunning { try? self.engine.start() }
            guard !self.music.isPlaying else { return }
            self.music.scheduleBuffer(self.song(), at: nil, options: .loops)
            self.music.play()
        }
    }

    // MARK: - Synthesis helpers

    /// Pulse wave with variable duty cycle — the classic handset-buzzer timbre.
    private func pulse(_ phase: Double, duty: Double = 0.5) -> Double { phase - floor(phase) < duty ? 1 : -1 }
    private func tri(_ phase: Double) -> Double { let f = phase - floor(phase); return 4 * abs(f - 0.5) - 1 }

    private func buffer(_ seconds: Double) -> (AVAudioPCMBuffer, UnsafeMutablePointer<Float>, Int) {
        let n = max(1, Int(seconds * sr))
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        b.frameLength = b.frameCapacity
        let d = b.floatChannelData![0]
        for i in 0..<n { d[i] = 0 }
        return (b, d, n)
    }

    /// Note name like "C5", "F#4", "Bb3" → frequency.
    private func freq(_ name: String) -> Double? {
        let names: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard let first = name.first, var semi = names[first], let oct = Int(String(name.last!)) else { return nil }
        if name.contains("#") { semi += 1 }
        if name.dropFirst().contains("b") { semi -= 1 }
        let midi = (oct + 1) * 12 + semi
        return 440 * pow(2, Double(midi - 69) / 12)
    }

    /// "C6:1 G6:2 -" — note:lengthInSteps, "-" is a one-step rest.
    private func notes(_ score: String, step: Double, vol: Double, duty: Double = 0.5) -> AVAudioPCMBuffer {
        let tokens = score.split(separator: " ").map(String.init)
        let total = tokens.reduce(0) { $0 + (Int($1.split(separator: ":").last ?? "1") ?? 1) }
        let (b, d, n) = buffer(Double(total) * step + 0.02)
        var pos = 0
        for t in tokens {
            let parts = t.split(separator: ":")
            let steps = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
            let len = Int(Double(steps) * step * sr)
            if let f = freq(String(parts[0])) {
                for j in 0..<len where pos + j < n {
                    let env = min(1, Double(j) / 60) * (j > len - 200 ? Double(len - j) / 200 : 1)
                    d[pos + j] += Float(pulse(f * Double(j) / sr, duty: duty) * env * vol)
                }
            }
            pos += len
        }
        return b
    }

    private func sweep(from f0: Double, to f1: Double, len: Double, vol: Double) -> AVAudioPCMBuffer {
        let (b, d, n) = buffer(len)
        var phase = 0.0
        for j in 0..<n {
            let t = Double(j) / Double(n)
            phase += (f0 * pow(f1 / f0, t)) / sr
            d[j] = Float(pulse(phase, duty: 0.25) * vol * (1 - t * 0.6))
        }
        return b
    }

    private func wobble(len: Double, vol: Double) -> AVAudioPCMBuffer {
        let (b, d, n) = buffer(len)
        var phase = 0.0
        for j in 0..<n {
            let t = Double(j) / sr
            phase += (520 + sin(t * 2 * .pi * 14) * 160 - t * 300) / sr
            d[j] = Float(pulse(phase) * vol * (1 - Double(j) / Double(n)))
        }
        return b
    }

    private func noise(_ len: Double, vol: Double) -> AVAudioPCMBuffer {
        let (b, d, n) = buffer(len)
        var hold = 0.0
        for j in 0..<n {
            if j % 6 == 0 { hold = Double.random(in: -1...1) }   // sample-and-hold = crunchy 8-bit noise
            d[j] = Float(hold * vol * pow(1 - Double(j) / Double(n), 2))
        }
        return b
    }

    private func mix(_ a: AVAudioPCMBuffer, _ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let (out, d, n) = buffer(Double(max(a.frameLength, b.frameLength)) / sr)
        for src in [a, b] { let s = src.floatChannelData![0]; for i in 0..<min(n, Int(src.frameLength)) { d[i] += s[i] } }
        return out
    }

    // MARK: - Music

    /// Original 16-bar chiptune: pulse lead, triangle bass, noise hi-hats. One token = an eighth note.
    private func song() -> AVAudioPCMBuffer {
        let lead = """
        C5 E5 G5 E5 A5 ~ G5 - | F5 E5 D5 E5 C5 ~ - - | D5 F5 A5 F5 B5 ~ A5 - | G5 F5 E5 D5 G5 ~ - - |
        E5 G5 C6 ~ B5 A5 G5 E5 | F5 A5 G5 F5 E5 ~ D5 - | C5 D5 E5 G5 A5 G5 E5 D5 | C5 ~ G4 ~ C5 ~ - - |
        E5 E5 G5 - E5 E5 A5 - | G5 F5 E5 F5 G5 ~ - - | A5 A5 C6 - A5 G5 F5 - | E5 D5 C5 D5 E5 ~ - - |
        C6 ~ B5 A5 G5 ~ E5 - | F5 ~ E5 D5 C5 ~ A4 - | B4 C5 D5 F5 E5 D5 C5 B4 | C5 ~ ~ ~ - - - -
        """
        let bassRoots = ["C3", "F2", "D3", "G2", "C3", "F2", "C3", "G2", "A2", "E3", "F2", "C3", "A2", "F2", "G2", "C3"]
        let tokens = lead.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "|" }).map(String.init)
        let bpm = 140.0, step = 60 / bpm / 2
        let stepFrames = Int(step * sr)
        let (b, d, n) = buffer(Double(tokens.count) * step)

        // Lead: walk tokens, merging ties into one note.
        var i = 0
        while i < tokens.count {
            var len = 1
            while i + len < tokens.count && tokens[i + len] == "~" { len += 1 }
            if let f = freq(tokens[i]) {
                let frames = len * stepFrames - 300
                let start = i * stepFrames
                for j in 0..<frames where start + j < n {
                    let t = Double(j) / sr
                    let vib = 1 + (t > 0.15 ? sin(t * 2 * .pi * 6) * 0.004 : 0)
                    let env = min(1, Double(j) / 80) * max(0.55, 1 - t * 1.5) * (j > frames - 300 ? Double(frames - j) / 300 : 1)
                    d[start + j] += Float(pulse(f * vib * t, duty: 0.25) * env * 0.16)
                }
            }
            i += len
        }
        // Bass + hats
        for bar in 0..<bassRoots.count {
            guard let root = freq(bassRoots[bar]) else { continue }
            for s in 0..<8 {
                let start = (bar * 8 + s) * stepFrames
                let f = s % 2 == 0 ? root : root * 2
                for j in 0..<(stepFrames - 200) where start + j < n {
                    let t = Double(j) / sr
                    d[start + j] += Float(tri(f * t) * exp(-t * 6) * 0.30)
                    if s % 2 == 1 { d[start + j] += Float(Double.random(in: -1...1) * exp(-t * 60) * 0.05) }
                }
            }
        }
        return b
    }
}

enum Haptics {
    static var on = true
    static func tap(_ intensity: CGFloat) {
        #if os(iOS)
        guard on else { return }
        DispatchQueue.main.async { UIImpactFeedbackGenerator(style: intensity > 0.8 ? .heavy : .light).impactOccurred(intensity: intensity) }
        #endif
    }
}
