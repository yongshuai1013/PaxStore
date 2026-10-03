import AVFoundation

// MARK: - 靜音保活（安裝時讓 App 在後台持續運行）
final class AudioKeepAlive {
    static let shared = AudioKeepAlive()
    private var player: AVAudioPlayer?
    private init() {}

    func start() {
        guard player == nil else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            guard let url = Bundle.main.url(forResource: "silence", withExtension: "wav") else { return }
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1
            p.volume = 0
            p.play()
            player = p
        } catch {
            print("[AudioKeepAlive] start failed: \(error)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
