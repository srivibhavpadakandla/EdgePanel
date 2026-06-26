import AVFoundation
import Foundation

/// Keeps the app alive in the background **only while a task is running**, so the
/// poll loop keeps going when your phone is locked — meaning EdgePanel sees the
/// turn finish and ends the Live Activity in real time (the timer stops exactly
/// when the task is done), then goes back to sleep.
///
/// Mechanism: a silent, looping audio session (`.playback` + `.mixWithOthers`, so
/// it never interrupts your music). iOS keeps an app with active playback alive in
/// the background. This is a personal-use technique (not App-Store-allowed) and
/// costs a little battery — but only during active turns, then it stops.
@MainActor
final class KeepAlive {
    static let shared = KeepAlive()
    private var player: AVAudioPlayer?
    private(set) var active = false

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    func start() {
        guard !active else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            let p = try AVAudioPlayer(contentsOf: Self.silenceURL())
            p.numberOfLoops = -1
            p.volume = 0
            p.prepareToPlay()
            p.play()
            player = p
            active = true
        } catch {
            active = false
        }
    }

    func stop() {
        guard active else { return }
        player?.stop(); player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        active = false
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard active,
              let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended {
            // A call / Siri ended — bring our keep-alive playback back.
            try? AVAudioSession.sharedInstance().setActive(true)
            player?.play()
        }
    }

    /// A tiny silent WAV written once to tmp (1s mono 16-bit PCM of zeros).
    private static func silenceURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("edgepanel-silence.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let sampleRate = 8000, seconds = 1
        let dataSize = sampleRate * seconds * 2
        var d = Data()
        func ascii(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        ascii("RIFF"); u32(UInt32(36 + dataSize)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        ascii("data"); u32(UInt32(dataSize))
        d.append(Data(count: dataSize))
        try? d.write(to: url)
        return url
    }
}
