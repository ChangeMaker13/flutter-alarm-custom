import AVFoundation
import os.log

class AppTerminateManager: NSObject {
    static let shared = AppTerminateManager()

    private static let logger = OSLog(subsystem: ALARM_BUNDLE, category: "AppTerminateManager")

    private var notificationTitleOnKill: String? = nil
    private var notificationBodyOnKill: String? = nil
    private var observerAdded: Bool = false

    private var isRinging : (() -> Bool)? = nil

    override private init() {
        super.init()
        os_log(.debug, log: AppTerminateManager.logger, "AppTerminateManager initialized.")
        self.cancelRepeatingAlarm()
    }

    func setWarningNotification(title: String, body: String) {
        self.notificationTitleOnKill = title
        self.notificationBodyOnKill = body
    }

    func startMonitoring(isRingingCallBack : @escaping () -> Bool) {
        if self.observerAdded {
            os_log(.debug, log: AppTerminateManager.logger, "App terminate monitoring already active.")
            return
        }

        self.isRinging = isRingingCallBack

        NotificationCenter.default.addObserver(self, selector: #selector(self.appWillTerminate(notification:)), name: UIApplication.willTerminateNotification, object: nil)
        self.observerAdded = true
        os_log(.debug, log: AppTerminateManager.logger, "App terminate monitoring started.")
    }

    func stopMonitoring() {
        if !self.observerAdded {
            os_log(.debug, log: AppTerminateManager.logger, "App terminate monitoring already inactive.")
            return
        }

        NotificationCenter.default.removeObserver(self, name: UIApplication.willTerminateNotification, object: nil)
        self.observerAdded = false
        os_log(.debug, log: AppTerminateManager.logger, "App terminate monitoring stopped.")
    }

    @objc private func appWillTerminate(notification: Notification) {
        os_log(.info, log: AppTerminateManager.logger, "App is going to terminate.")
        os_log(.info, log: AppTerminateManager.logger, "callback nil: %{public}@", String(describing: self.isRinging))
        os_log(.info, log: AppTerminateManager.logger, "is ringing: %{public}@", String(describing: self.isRinging?() ?? false))

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            if(self.isRinging?() ?? false) {
                await self.backgroundAlarmChain()
            }
            else{
                await self.sendWarningNotification()
            }
            semaphore.signal()
        }
        semaphore.wait()
    }

    private func sendWarningNotification() async {
        let title = self.notificationTitleOnKill ?? "Your alarms may not ring"
        let body = self.notificationBodyOnKill ?? "You killed the app. Please reopen so your alarms can be rescheduled."
        await NotificationManager.shared.sendWarningNotification(title: title, body: body)
    }

    ///------- 알람 체인을 구현을 위해 수정된 부분
    private func backgroundAlarmChain() async {
        
        for i in 0...19 {
            await self.schedule60SecondRepeatingAlarm(afterSeconds: i * 3)
        }
    }

    private func schedule60SecondRepeatingAlarm(afterSeconds : Int) async
    {
        let center = UNUserNotificationCenter.current()
        
        // 알림 내용 설정
        let content = UNMutableNotificationContent()
        content.title = "Don't snooze"
        content.body = "Your alarm is ringing. Please reopen the app to stop it."
        if let soundURL = Bundle.main.url(forResource: "bell9", withExtension: "m4a") {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(soundURL.lastPathComponent))
        } else {
            content.sound = UNNotificationSound.default
        }

        // IOS15.0 이상에서만 실행되도록
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .critical
        }
        
        var date = DateComponents()
        date.second = afterSeconds

        // 해당 시간부터 60초마다 반복
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: date,
            repeats: true
        )

        let request = UNNotificationRequest(
            identifier: "delayed_repeating_alarm_\(afterSeconds)",
            content: content,
            trigger: trigger
        )
        os_log(.debug, log: AppTerminateManager.logger, "Scheduled repeating alarm: %{public}@", request.identifier)
        
        try? await center.add(request)
    }

    func cancelRepeatingAlarm() {
        for i in 0...19 {
            let identifier = "delayed_repeating_alarm_\(i*3)"
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
            os_log(.debug, log: AppTerminateManager.logger, "Canceled repeating alarm: %{public}@", identifier)
        }
    }
}
