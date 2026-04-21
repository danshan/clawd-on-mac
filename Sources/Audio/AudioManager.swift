import AppKit
import AVFoundation
import os

private let logger = Logger(subsystem: "com.clawd.onmac", category: "AudioManager")

class AudioManager {

    private var audioCache: [String: AVAudioPlayer] = [:]
    private var lastPlayTime: Date = Date.distantPast
    private let COOLDOWN_SECONDS: Double = 10

    var isMuted: Bool = false
    var doNotDisturb: Bool = false

    func playSound(_ name: String) {
        guard !isMuted && !doNotDisturb else { return }

        let now = Date()
        guard now.timeIntervalSince(lastPlayTime) >= COOLDOWN_SECONDS else { return }

        let soundName: String
        switch name {
        case "complete": soundName = "complete.mp3"
        case "confirm": soundName = "confirm.mp3"
        default: soundName = "\(name).mp3"
        }

        if let cached = audioCache[soundName] {
            cached.currentTime = 0
            cached.play()
            lastPlayTime = now
            return
        }

        guard let path = Bundle.main.path(forResource: soundName, ofType: nil, inDirectory: "Resources/sounds") else {
            logger.debug("Sound file not found: \(soundName, privacy: .public)")
            return
        }

        let url = URL(fileURLWithPath: path)
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }

        player.prepareToPlay()
        player.play()
        audioCache[soundName] = player
        lastPlayTime = now
    }

    func preloadSounds() {
        let soundFiles = ["complete.mp3", "confirm.mp3"]

        for soundFile in soundFiles {
            guard let path = Bundle.main.path(forResource: soundFile, ofType: nil, inDirectory: "Resources/sounds") else {
                continue
            }

            let url = URL(fileURLWithPath: path)
            if let player = try? AVAudioPlayer(contentsOf: url) {
                player.prepareToPlay()
                audioCache[soundFile] = player
            }
        }
    }
}