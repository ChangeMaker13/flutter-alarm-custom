import Flutter
import os.log

class AlarmManager: NSObject {
    private static let logger = OSLog(subsystem: ALARM_BUNDLE, category: "AlarmManager")

    private let registrar: FlutterPluginRegistrar

    private var alarms: [Int: AlarmConfiguration] = [:]

    init(registrar: FlutterPluginRegistrar) {
        self.registrar = registrar
        super.init()
    }

    func setAlarm(alarmSettings: AlarmSettings) async {
        if self.alarms.keys.contains(alarmSettings.id) {
            os_log(.info, log: AlarmManager.logger, "Stopping alarm with identical ID=%d before scheduling a new one.", alarmSettings.id)
            await self.stopAlarm(id: alarmSettings.id, cancelNotif: true)
        }

        let config = AlarmConfiguration(settings: alarmSettings)
        self.alarms[alarmSettings.id] = config

        let delayInSeconds = alarmSettings.dateTime.timeIntervalSinceNow
        let ringImmediately = delayInSeconds < 1
        if !ringImmediately {
            let timer = Timer(timeInterval: delayInSeconds,
                              target: self,
                              selector: #selector(self.alarmTimerTrigerred(_:)),
                              userInfo: alarmSettings.id,
                              repeats: false)
            RunLoop.main.add(timer, forMode: .common)
            config.timer = timer
        }

        self.updateState()

        if ringImmediately {
            os_log(.info, log: AlarmManager.logger, "Ringing alarm ID=%d immediately.", alarmSettings.id)
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(delayInSeconds, 0.1) * 1_000_000_000))
                await self.ringAlarm(id: alarmSettings.id)
            }
        }

        os_log(.info, log: AlarmManager.logger, "Set alarm for ID=%d complete.", alarmSettings.id)
    }

    func stopAlarm(id: Int, cancelNotif: Bool) async {
        if cancelNotif {
            NotificationManager.shared.cancelNotification(id: id)
        }
        NotificationManager.shared.dismissNotification(id: id)

        await AlarmRingManager.shared.stop()

        if let config = self.alarms[id] {
            config.timer?.invalidate()
            config.timer = nil
            self.alarms.removeValue(forKey: id)
        }

        self.updateState()

        await self.notifyAlarmStopped(id: id)

        os_log(.info, log: AlarmManager.logger, "Stop alarm for ID=%d complete.", id)
    }

    func stopAll() async {
        await NotificationManager.shared.removeAllNotifications()

        await AlarmRingManager.shared.stop()

        let alarmIds = Array(self.alarms.keys)
        self.alarms.forEach { $0.value.timer?.invalidate() }
        self.alarms.removeAll()

        self.updateState()

        for alarmId in alarmIds {
            await self.notifyAlarmStopped(id: alarmId)
        }

        os_log(.info, log: AlarmManager.logger, "Stop all complete.")
    }

    func isRinging(id: Int? = nil) -> Bool {
        guard let alarmId = id else {
            return self.alarms.values.contains(where: { $0.state == .ringing })
        }
        return self.alarms[alarmId]?.state == .ringing
    }

    /// Ensures all alarm timers are valid and reschedules them if not.
    func checkAlarms() async {
        var rescheduled = 0
        for (id, config) in self.alarms {
            if config.state == .ringing || config.timer?.isValid ?? false {
                continue
            }

            rescheduled += 1

            config.timer?.invalidate()
            config.timer = nil

            let delayInSeconds = config.settings.dateTime.timeIntervalSinceNow
            if delayInSeconds <= 0 {
                await self.ringAlarm(id: id)
                continue
            }
            if delayInSeconds < 1 {
                try? await Task.sleep(nanoseconds: UInt64(delayInSeconds * 1_000_000_000))
                await self.ringAlarm(id: id)
                continue
            }

            let timer = Timer(timeInterval: delayInSeconds,
                              target: self,
                              selector: #selector(self.alarmTimerTrigerred(_:)),
                              userInfo: config.settings.id,
                              repeats: false)
            RunLoop.main.add(timer, forMode: .common)
            config.timer = timer
        }

        os_log(.info, log: AlarmManager.logger, "Check alarms complete. Rescheduled %d timers.", rescheduled)
    }

    @objc private func alarmTimerTrigerred(_ timer: Timer) {
        guard let alarmId = timer.userInfo as? Int else {
            os_log(.error, log: AlarmManager.logger, "Alarm timer had invalid userInfo: %@", String(describing: timer.userInfo))
            return
        }
        Task {

            await self.ringAlarm(id: alarmId)
        }
    }

    private func ringAlarm(id: Int) async {
        guard let config = self.alarms[id] else {
            os_log(.error, log: AlarmManager.logger, "Alarm %d was not found and cannot be rung.", id)
            return
        }

        ///------- 알람 체인을 구현을 위해 수정된 부분
        // 백업 알람 예약 (20초 후)
        // let backupId = id + 10000 + Int(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 90000))
        // let backupSettings = AlarmSettings(
        //     id: backupId,
        //     dateTime: Date().addingTimeInterval(20),
        //     assetAudioPath: config.settings.assetAudioPath,
        //     volumeSettings: config.settings.volumeSettings,
        //     notificationSettings: config.settings.notificationSettings,
        //     loopAudio: config.settings.loopAudio,
        //     vibrate: config.settings.vibrate,
        //     warningNotificationOnKill: config.settings.warningNotificationOnKill,
        //     androidFullScreenIntent: config.settings.androidFullScreenIntent,
        //     allowAlarmOverlap: config.settings.allowAlarmOverlap,
        //     iOSBackgroundAudio: config.settings.iOSBackgroundAudio
        // )
        
        // os_log(.info, log: AlarmManager.logger, "Scheduling backup alarm with ID=%d for 5 seconds later", backupId)
        
        // // 백업 알람 설정
        // do {
        //     try await self.setAlarm(alarmSettings: backupSettings)
        //     os_log(.debug, log: AlarmManager.logger, "Successfully scheduled backup alarm with ID=%d", backupId)
        // } catch {
        //     os_log(.error, log: AlarmManager.logger, "Failed to schedule backup alarm: %@", error.localizedDescription)
        // }

        // await self.notifyAlarmRang(id: id)
        ///-------

        /// 메인 플러터 앱에서 alarm state를 확인하는 부분(idle 상태가 맞는지. 아니라면 알람 취소)
        // FlutterSharedPreferences에서 "alarm_state" 값을 읽어온다.
        let prefs = UserDefaults(suiteName: "FlutterSharedPreferences")
        let alarmState = prefs?.string(forKey: "flutter.alarm_state") ?? "idle"

        os_log("[package_test] prefs.string(forKey: \"alarm_state\") : %@", alarmState)

        // 메인 Flutter 앱의 알람 상태 확인
        if alarmState != "idle" {
            os_log("Alarm state is not idle. Ignoring new alarm with id: %d", id)
            await self.stopAlarm(id: id, cancelNotif: true)
            return
        }
        ///-------

        if !config.settings.allowAlarmOverlap && self.alarms.contains(where: { $1.state == .ringing }) {
            os_log(.error, log: AlarmManager.logger, "Ignoring alarm with id %d because another alarm is already ringing.", id)
            await self.stopAlarm(id: id, cancelNotif: true)
            return
        }

        if config.state == .ringing {
            os_log(.error, log: AlarmManager.logger, "Alarm %d is already ringing.", id)
            return
        }

        os_log(.debug, log: AlarmManager.logger, "Ringing alarm %d...", id)

        config.state = .ringing
        config.timer?.invalidate()
        config.timer = nil

        await NotificationManager.shared.showNotification(id: config.settings.id, notificationSettings: config.settings.notificationSettings)

        // Ensure background audio is stopped before ringing alarm.
        BackgroundAudioManager.shared.stop()

        await AlarmRingManager.shared.start(
            registrar: self.registrar,
            assetAudioPath: config.settings.assetAudioPath,
            loopAudio: config.settings.loopAudio,
            volumeSettings: config.settings.volumeSettings,
            onComplete: config.settings.loopAudio ? { [weak self] in
                Task {
                    [self] in await self?.stopAlarm(id: id, cancelNotif: false)
                }
            } : nil)

        self.updateState()

        await self.notifyAlarmRang(id: id)

        os_log(.info, log: AlarmManager.logger, "Ring alarm for ID=%d complete.", id)
    }

    @MainActor
    private func notifyAlarmRang(id: Int) async {
        await withCheckedContinuation { continuation in
            guard let triggerApi = SwiftAlarmPlugin.getTriggerApi() else {
                os_log(.error, log: AlarmManager.logger, "AlarmTriggerApi.alarmRang was not setup!")
                continuation.resume()
                return
            }

            os_log(.info, log: AlarmManager.logger, "Informing the Flutter plugin that alarm %d has rang...", id)

            triggerApi.alarmRang(alarmId: Int64(id), completion: { result in
                if case .success = result {
                    os_log(.info, log: AlarmManager.logger, "Alarm rang notification for %d was processed successfully by Flutter.", id)
                } else {
                    os_log(.info, log: AlarmManager.logger, "Alarm rang notification for %d encountered error in Flutter.", id)
                }
                continuation.resume()
            })
        }
    }

    // @MainActor
    // private func notifyAlarmTriggered(alarmSettings: AlarmSettings) async {
    //     await withCheckedContinuation { continuation in
    //         guard let triggerApi = SwiftAlarmPlugin.getTriggerApi() else {
    //             os_log(.error, log: AlarmManager.logger, "AlarmTriggerApi.alarmTriggered was not setup!")
    //             continuation.resume()
    //             return
    //         }

    //         os_log(.info, log: AlarmManager.logger, "Informing the Flutter plugin that alarm %d has triggered...", alarmSettings.id)

    //         triggerApi.alarmTriggered(alarmSettings: alarmSettings, completion: { result in   
    //             if case .success = result {
    //                 os_log(.info, log: AlarmManager.logger, "Alarm triggered notification for %d was processed successfully by Flutter.", id)
    //             } else {
    //                 os_log(.info, log: AlarmManager.logger, "Alarm triggered notification for %d encountered error in Flutter.", id)
    //             }
    //             continuation.resume()   
    //         })
    //     }
    // }

    @MainActor
    private func notifyAlarmStopped(id: Int) async {
        await withCheckedContinuation { continuation in
            guard let triggerApi = SwiftAlarmPlugin.getTriggerApi() else {
                os_log(.error, log: AlarmManager.logger, "AlarmTriggerApi.alarmStopped was not setup!")
                continuation.resume()
                return
            }

            os_log(.info, log: AlarmManager.logger, "Informing the Flutter plugin that alarm %d has stopped...", id)

            triggerApi.alarmStopped(alarmId: Int64(id), completion: { result in
                if case .success = result {
                    os_log(.info, log: AlarmManager.logger, "Alarm stopped notification for %d was processed successfully by Flutter.", id)
                } else {
                    os_log(.info, log: AlarmManager.logger, "Alarm stopped notification for %d encountered error in Flutter.", id)
                }
                continuation.resume()
            })
        }
    }

    private func updateState() {
        if self.alarms.contains(where: { $1.state == .scheduled && $1.settings.warningNotificationOnKill }) {
            AppTerminateManager.shared.startMonitoring(isRingingCallBack: {
                return self.isRinging()
            })
        } else {
            AppTerminateManager.shared.stopMonitoring()
        }

        if !self.alarms.contains(where: { $1.state == .ringing }) && self.alarms.contains(where: { $1.state == .scheduled && $1.settings.iOSBackgroundAudio }) {
            BackgroundAudioManager.shared.start(registrar: self.registrar)
        } else {
            BackgroundAudioManager.shared.stop()
        }

        if self.alarms.contains(where: { $1.state == .scheduled }) {
            BackgroundTaskManager.enable()
        } else {
            BackgroundTaskManager.disable()
        }

        if self.alarms.contains(where: { $1.state == .ringing && $1.settings.vibrate }) {
            VibrationManager.shared.start()
        } else {
            VibrationManager.shared.stop()
        }

        os_log(.debug, log: AlarmManager.logger, "State updated.")
    }
}
