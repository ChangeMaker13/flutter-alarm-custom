import AVFoundation
import Flutter
import MediaPlayer
import os.log

class AlarmRingManager: NSObject {
    static let shared = AlarmRingManager()

    private static let logger = OSLog(subsystem: ALARM_BUNDLE, category: "AlarmRingManager")

    private var previousVolume: Float?
    private var volumeEnforcementTimer: Timer?
    private var audioPlayer: AVAudioPlayer?

    override private init() {
        super.init()
    }

    func start(registrar: FlutterPluginRegistrar, assetAudioPath: String, loopAudio: Bool, volumeSettings: VolumeSettings, onComplete: (() -> Void)?) async {
        let start = Date()

        self.duckOtherAudios()

        let targetSystemVolume: Float
        if let systemVolume = volumeSettings.volume.map({ Float($0) }) {
            targetSystemVolume = systemVolume
            self.previousVolume = await self.setSystemVolume(volume: systemVolume)
        } else {
            targetSystemVolume = self.getSystemVolume()
        }

        if volumeSettings.volumeEnforced {
            let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
                os_log(.debug, log: AlarmRingManager.logger, "Enforcement timer triggered")
                AlarmRingManager.shared.enforcementTimerTriggered(targetSystemVolume: targetSystemVolume)
            }
            RunLoop.main.add(timer, forMode: .common)
            self.volumeEnforcementTimer = timer
        }

        guard let audioPlayer = self.loadAudioPlayer(registrar: registrar, assetAudioPath: assetAudioPath) else {
            await self.stop()
            return
        }

        if loopAudio {
            audioPlayer.numberOfLoops = -1
        }

        audioPlayer.prepareToPlay()
        audioPlayer.volume = 0.0
        audioPlayer.play()
        self.audioPlayer = audioPlayer

        if !volumeSettings.fadeSteps.isEmpty {
            self.fadeVolume(steps: volumeSettings.fadeSteps)
        } else if let fadeDuration = volumeSettings.fadeDuration {
            self.fadeVolume(steps: [VolumeFadeStep(time: 0, volume: 0), VolumeFadeStep(time: fadeDuration, volume: 1.0)])
        } else {
            audioPlayer.volume = 1.0
        }

        if !loopAudio {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(audioPlayer.duration * 1_000_000_000))
                onComplete?()
            }
        }

        let runDuration = Date().timeIntervalSince(start)
        os_log(.debug, log: AlarmRingManager.logger, "Alarm ring started in %.2fs.", runDuration)
    }

    func stop() async {
        if self.volumeEnforcementTimer == nil && self.previousVolume == nil && self.audioPlayer == nil {
            os_log(.debug, log: AlarmRingManager.logger, "Alarm ringer already stopped.")
            return
        }

        let start = Date()

        self.mixOtherAudios()

        self.volumeEnforcementTimer?.invalidate()
        self.volumeEnforcementTimer = nil

        if let previousVolume = self.previousVolume {
            await self.setSystemVolume(volume: previousVolume)
            self.previousVolume = nil
        }

        self.audioPlayer?.stop()
        self.audioPlayer = nil

        let runDuration = Date().timeIntervalSince(start)
        os_log(.debug, log: AlarmRingManager.logger, "Alarm ring stopped in %.2fs.", runDuration)
    }

    private func duckOtherAudios() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .default, options: [.duckOthers])
            try audioSession.setActive(true)
            os_log(.debug, log: AlarmRingManager.logger, "Stopped other audio sources.")
        } catch {
            os_log(.error, log: AlarmRingManager.logger, "Error setting up audio session with option duckOthers: %@", error.localizedDescription)
        }
    }

    private func mixOtherAudios() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)
            os_log(.debug, log: AlarmRingManager.logger, "Play concurrently with other audio sources.")
        } catch {
            os_log(.error, log: AlarmRingManager.logger, "Error setting up audio session with option mixWithOthers: %@", error.localizedDescription)
        }
    }

    private func getSystemVolume() -> Float {
        let audioSession = AVAudioSession.sharedInstance()
        return audioSession.outputVolume
    }

    @discardableResult
    @MainActor
    private func setSystemVolume(volume: Float) async -> Float? {
        let volumeView = MPVolumeView()
         volumeView.frame = CGRect(x: -1000, y: -1000, width: 100, height: 100)
        volumeView.showsVolumeSlider = true
        volumeView.showsRouteButton = false 

        guard let keyWindow = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) else {
            os_log(.error, log: AlarmRingManager.logger, "No key window found")
            return nil
        }

        keyWindow.addSubview(volumeView)
    
        // We need to pause for 300ms to ensure the slider loads.
        try? await Task.sleep(nanoseconds: UInt64(0.3 * 1_000_000_000))

        guard let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider else {
            os_log(.error, log: AlarmRingManager.logger, "Volume slider could not be found.")
            volumeView.removeFromSuperview()
            return nil
        }

        let previousVolume = slider.value
        os_log(.info, log: AlarmRingManager.logger, "Setting system volume to %f.", volume)
        slider.value = volume
        volumeView.removeFromSuperview()

        return previousVolume
    }

    @objc private func enforcementTimerTriggered(targetSystemVolume: Float) {
        Task {
            let currentSystemVolume = self.getSystemVolume()
            if abs(currentSystemVolume - targetSystemVolume) > 0.01 {
                os_log(.debug, log: AlarmRingManager.logger, "System volume changed. Restoring to %f.", targetSystemVolume)
                //await self.setSystemVolume(volume: targetSystemVolume)

                // 👇 메인 스레드에서 실행하도록 수정
                await MainActor.run {
                    Task {
                        let result = await self.setSystemVolume(volume: targetSystemVolume)
                        os_log(.debug, log: AlarmRingManager.logger, "setSystemVolume result: %@", String(describing: result))
                        
                        // 볼륨 설정 후 실제 볼륨 확인
                        let newVolume = self.getSystemVolume()
                        os_log(.debug, log: AlarmRingManager.logger, "Volume after setting: %f", newVolume)
                    }
                }
            }
        }
    }

    private func loadAudioPlayer(registrar: FlutterPluginRegistrar, assetAudioPath: String) -> AVAudioPlayer? {
        let audioURL: URL
        if assetAudioPath.hasPrefix("assets/") || assetAudioPath.hasPrefix("asset/") {
            let filename = registrar.lookupKey(forAsset: assetAudioPath)
            guard let audioPath = Bundle.main.path(forResource: filename, ofType: nil) else {
                os_log(.error, log: AlarmRingManager.logger, "Audio file not found: %@", assetAudioPath)
                return nil
            }
            audioURL = URL(fileURLWithPath: audioPath)
        } else {
            guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                os_log(.error, log: AlarmRingManager.logger, "Document directory not found.")
                return nil
            }
            audioURL = documentsDirectory.appendingPathComponent(assetAudioPath)
        }

        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: audioURL)
            os_log(.debug, log: AlarmRingManager.logger, "Audio player loaded from: %@", assetAudioPath)
            return audioPlayer
        } catch {
            os_log(.error, log: AlarmRingManager.logger, "Error loading audio player: %@", error.localizedDescription)
            return nil
        }
    }

    private func fadeVolume(steps: [VolumeFadeStep]) {
        guard let audioPlayer = self.audioPlayer else {
            os_log(.error, log: AlarmRingManager.logger, "Cannot fade volume because audioPlayer is nil.")
            return
        }

        if !audioPlayer.isPlaying {
            os_log(.error, log: AlarmRingManager.logger, "Cannot fade volume because audioPlayer isn't playing.")
            return
        }

        audioPlayer.volume = Float(steps[0].volume)

        for i in 0 ..< steps.count - 1 {
            let startTime = steps[i].time
            let nextStep = steps[i + 1]
            // Subtract 50ms to avoid weird jumps that might occur when two fades collide.
            let fadeDuration = nextStep.time - startTime - 0.05
            let targetVolume = Float(nextStep.volume)

            // Schedule the fade using setVolume for a smooth transition
            Task {
                try? await Task.sleep(nanoseconds: UInt64(startTime * 1_000_000_000))
                if !audioPlayer.isPlaying {
                    return
                }
                os_log(.info, log: AlarmRingManager.logger, "Fading volume to %f over %f seconds.", targetVolume, fadeDuration)
                audioPlayer.setVolume(targetVolume, fadeDuration: fadeDuration)
            }
        }
    }
}
