package com.gdelataillade.alarm.alarm

import com.gdelataillade.alarm.services.AudioService
import com.gdelataillade.alarm.services.AlarmStorage
import com.gdelataillade.alarm.services.VibrationService
import com.gdelataillade.alarm.services.VolumeService
import com.gdelataillade.alarm.services.StopRequestTracker

import android.app.Service
import android.app.PendingIntent
import android.app.ForegroundServiceStartNotAllowedException
import android.app.Notification
import android.content.Intent
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.PowerManager
import android.os.Build
import com.gdelataillade.alarm.models.AlarmSettings
import com.gdelataillade.alarm.services.AlarmRingingLiveData
import com.gdelataillade.alarm.services.NotificationHandler
import com.gdelataillade.alarm.services.NotificationOnKillService
import io.flutter.Log
import kotlinx.serialization.json.Json

class AlarmService : Service() {
    companion object {
        private const val TAG = "AlarmService"

        var instance: AlarmService? = null

        @JvmStatic
        var ringingAlarmIds: List<Int> = listOf()
    }

    private var alarmId: Int = 0
    private var audioService: AudioService? = null
    private var vibrationService: VibrationService? = null
    private var volumeService: VolumeService? = null
    private var alarmStorage: AlarmStorage? = null
    private var showSystemUI: Boolean = true
    private var shouldStopAlarmOnTermination: Boolean = true

    override fun onCreate() {
        super.onCreate()

        instance = this
        audioService = AudioService(this)
        vibrationService = VibrationService(this)
        volumeService = VolumeService(this)
        alarmStorage = AlarmStorage(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "OnStartCommand 실행")

        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }

        val id = intent.getIntExtra("id", 0)
        alarmId = id
        val action = intent.getStringExtra(AlarmReceiver.EXTRA_ALARM_ACTION)

        if (action == "STOP_ALARM" && id != 0) {
            unsaveAlarm(id)
            return START_NOT_STICKY
        }

        /// 메인 플러터 앱에서 alarm state를 확인하는 부분(idle 상태가 맞는지. 아니라면 알람 취소)
        
        //백업알람에는 id에 백업알람임을 나타내는 표식이 있음. 백업알람이라면 확인 x
        val isBackupalarm = id.toString().startsWith("123456789");
        if(!isBackupalarm){
            // sharedPreference에서 "alarm_state"로 값 가져오기
                    val prefs = applicationContext.getSharedPreferences(
                "FlutterSharedPreferences",
                Context.MODE_PRIVATE
            )
            
            val alarm_state = prefs.getString("flutter.alarm_state", "idle")

            Log.d(TAG, "[package_test] prefs.getString(\"alarm_state\", \"idle\") : $alarm_state")

            // Check mission state of main flutter app
            if (alarm_state != "idle") {
                Log.d(TAG, "Alarm state is not idle. Ignoring new alarm with id: $id")
                unsaveAlarm(id, false)
                return START_NOT_STICKY
            }
        }
        ///끝 

        // Build the notification
        val notificationHandler = NotificationHandler(this)
        val appIntent =
            applicationContext.packageManager.getLaunchIntentForPackage(applicationContext.packageName)
        val pendingIntent = PendingIntent.getActivity(
            this,
            id,
            appIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val alarmSettingsJson = intent.getStringExtra("alarmSettings")
        if (alarmSettingsJson == null) {
            Log.e(TAG, "Intent is missing AlarmSettings.")
            stopSelf()
            return START_NOT_STICKY
        }

        val alarmSettings: AlarmSettings
        try {
            alarmSettings = Json.decodeFromString<AlarmSettings>(alarmSettingsJson)
        } catch (e: Exception) {
            Log.e(TAG, "Cannot parse AlarmSettings from Intent.")
            stopSelf()
            return START_NOT_STICKY
        }

        val notification = notificationHandler.buildNotification(
            alarmSettings.notificationSettings,
            alarmSettings.androidFullScreenIntent,
            pendingIntent,
            id
        )

        // Start the service in the foreground
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                try {
                    startAlarmService(id, notification)
                } catch (e: ForegroundServiceStartNotAllowedException) {
                    Log.e(TAG, "Foreground service start not allowed", e)
                    return START_NOT_STICKY
                }
            } else {
                startAlarmService(id, notification)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Exception while starting foreground service: ${e.message}", e)
            return START_NOT_STICKY
        }

        ///--------- 알람 체인 구현을 위해 수정된 부분
        // 현재 알람 설정이 있다면 5초 후 백업 알람 예약
        try {
            // 새로운 알람 ID 생성 (기존 ID + 10000 + 현재 시간의 일부)
            var backupId = 239891249;
            if(isBackupalarm){
                backupId = 1234567890 + (((id % 1234567890) + 1) % 10);
            }
            else {
                backupId = 1234567890;
            }
            
            // 동일한 알람 설정으로 복사하되 새 ID와 시간 설정
            val backupSettings = alarmSettings.copy(
                id = backupId,
                dateTime = java.util.Date(System.currentTimeMillis() + 20000) // 20초 후
            )
            
            Log.d(TAG, "Scheduling backup alarm with ID=$backupId for 20 seconds later")
            
            // AlarmApiImpl을 통해 백업 알람 예약
            val alarmApiImpl = com.gdelataillade.alarm.api.AlarmApiImpl(this)
            alarmApiImpl.setAlarm(backupSettings)
            
            Log.d(TAG, "Successfully scheduled backup alarm with ID=$backupId")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to schedule backup alarm: ${e.message}", e)
        }

        AlarmPlugin.alarmTriggerApi?.alarmRang(id.toLong()) {
        }
        ///---------

        // Check if an alarm is already ringing
        if (!alarmSettings.allowAlarmOverlap && ringingAlarmIds.isNotEmpty() && action != "STOP_ALARM") {
            Log.d(TAG, "An alarm is already ringing. Ignoring new alarm with id: $id")
            unsaveAlarm(id, false)
            return START_NOT_STICKY
        }

        // 알람이 실제로 저장소에 존재하는지 확인
        val alarmExists = alarmStorage?.checkAlarmExists(id) ?: false
        if (!alarmExists) {
            Log.d(TAG, "Alarm with id $id no longer exists in storage. It may have been stopped already. Ignoring.")
            return START_NOT_STICKY
        }
        
        // 이미 중지 요청이 있었는지 확인
        if (StopRequestTracker.isStopRequested(id)) {
            Log.d(TAG, "Alarm with id $id was requested to stop. Ignoring alarm start request.")
            StopRequestTracker.clearStopRequest(id)
            return START_NOT_STICKY
        }

        if (alarmSettings.androidFullScreenIntent) {
            AlarmRingingLiveData.instance.update(true)
        }

        // Notify the plugin about the alarm ringing
        AlarmPlugin.alarmTriggerApi?.alarmRang(id.toLong()) {
            // 알람이 성공적으로 시작된 경우에만 처리
            if (it.isSuccess) {
                Log.d(TAG, "Alarm rang notification for $id was processed successfully by Flutter.")
            } else {
                // 오류 발생 시(예: 알람을 찾을 수 없음) 알람을 중지
                Log.d(TAG, "Alarm rang notification for $id encountered error in Flutter. Stopping this alarm.")
                if(shouldStopAlarmOnTermination) {
                    stopAlarm(id)
                }
            }
        }

        // Set the volume if specified
        if (alarmSettings.volumeSettings.volume != null) {
            volumeService?.setVolume(
                alarmSettings.volumeSettings.volume,
                alarmSettings.volumeSettings.volumeEnforced,
                showSystemUI
            )
        }

        // Request audio focus
        volumeService?.requestAudioFocus()

        // Set up audio completion listener
        audioService?.setOnAudioCompleteListener {
            if (!alarmSettings.loopAudio) {
                vibrationService?.stopVibrating()
                volumeService?.restorePreviousVolume(showSystemUI)
                volumeService?.abandonAudioFocus()
            }
        }

        // Play the alarm audio
        audioService?.playAudio(
            id,
            alarmSettings.assetAudioPath,
            alarmSettings.loopAudio,
            alarmSettings.volumeSettings.fadeDuration,
            alarmSettings.volumeSettings.fadeSteps
        )

        // Update the list of ringing alarms
        ringingAlarmIds = audioService?.getPlayingMediaPlayersIds() ?: listOf()

        // Start vibration if enabled
        if (alarmSettings.vibrate) {
            vibrationService?.startVibrating(longArrayOf(0, 500, 500), 1)
        }

        // Retrieve whether the alarm should be stopped on task termination
        shouldStopAlarmOnTermination = alarmSettings.androidStopAlarmOnTermination

        // Acquire a wake lock to wake up the device
        val wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "app:AlarmWakelockTag")
        wakeLock.acquire(5 * 60 * 1000L) // Acquire for 5 minutes

        // If there are no other alarms scheduled, turn off the warning notification.
        val storage = alarmStorage
        if (storage != null) {
            val storedAlarms = storage.getSavedAlarms()
            if (storedAlarms.isEmpty() || storedAlarms.all { it.id == id }) {
                val serviceIntent = Intent(this, NotificationOnKillService::class.java)
                // If the service isn't running this call will be ignored.
                this.stopService(serviceIntent)
                Log.d(TAG, "Turning off the warning notification.")
            } else {
                Log.d(TAG, "Keeping the warning notification on because there are other pending alarms.")
            }
        }

        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.d(TAG, "App closed, checking if alarm should be stopped.")

        if (shouldStopAlarmOnTermination) {
            Log.d(TAG, "Stopping alarm as androidStopAlarmOnTermination is true.")
            unsaveAlarm(alarmId)
            stopSelf()
        } else {
            Log.d(TAG, "Keeping alarm running as androidStopAlarmOnTermination is false.")
        }
        
        super.onTaskRemoved(rootIntent)
    }

    private fun startAlarmService(id: Int, notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                id,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(id, notification)
        }
    }

    fun handleStopAlarmCommand(alarmId: Int) {
        if (alarmId == 0) return
        unsaveAlarm(alarmId)
    }

    private fun unsaveAlarm(id: Int, shouldStopAlarm: Boolean = true) {
        // 1. 먼저 알람 중지
        if(shouldStopAlarm == true) stopAlarm(id)
        
        // 2. 그 다음 저장소에서 알람 정보 삭제
        alarmStorage?.unsaveAlarm(id)
        
        // 3. Flutter에 알람 중지 알림
        AlarmPlugin.alarmTriggerApi?.alarmStopped(id.toLong()) {
            if (it.isSuccess) {
                Log.d(TAG, "Alarm stopped notification for $id was processed successfully by Flutter.")
            } else {
                Log.d(TAG, "Alarm stopped notification for $id encountered error in Flutter.")
            }
        }
    }

    private fun stopAlarm(id: Int) {
        AlarmRingingLiveData.instance.update(false)
        try {
            val playingIds = audioService?.getPlayingMediaPlayersIds() ?: listOf()
            ringingAlarmIds = playingIds

            // Safely call methods on 'volumeService' and 'audioService'
            volumeService?.restorePreviousVolume(showSystemUI)
            volumeService?.abandonAudioFocus()

            audioService?.stopAudio(id)

            // Check if media player is empty safely
            if (audioService?.isMediaPlayerEmpty() == true) {
                vibrationService?.stopVibrating()
                stopSelf()
            }

            stopForeground(true)
        } catch (e: IllegalStateException) {
            Log.e(TAG, "Illegal State: ${e.message}", e)
        } catch (e: Exception) {
            Log.e(TAG, "Error in stopping alarm: ${e.message}", e)
        }
    }

    override fun onDestroy() {
        ringingAlarmIds = listOf()

        audioService?.cleanUp()
        vibrationService?.stopVibrating()
        volumeService?.restorePreviousVolume(showSystemUI)
        volumeService?.abandonAudioFocus()

        AlarmRingingLiveData.instance.update(false)

        stopForeground(true)
        instance = null

        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
