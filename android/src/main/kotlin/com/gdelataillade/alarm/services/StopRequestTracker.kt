package com.gdelataillade.alarm.services

import java.util.concurrent.ConcurrentHashMap

/**
 * 알람 중지 요청을 메모리에 추적하여 경쟁 상태(Race Condition)를 방지하는 싱글톤 클래스
 * 알람이 시작되는 시점과 중지 요청 시점이 거의 동시에 발생하는 경우를 처리하기 위함
 */
object StopRequestTracker {
    // 알람 ID를 키로 사용하여 중지 요청 상태를 저장하는 맵
    private val stoppedAlarms = ConcurrentHashMap<Int, Long>()
    
    // 알람 중지 요청 만료 시간 (밀리초)
    private const val EXPIRATION_TIME_MS = 5000L // 5초
    
    /**
     * 알람을 중지 요청 목록에 추가
     */
    fun markAlarmAsStopRequested(alarmId: Int) {
        stoppedAlarms[alarmId] = System.currentTimeMillis()
        cleanExpiredEntries()
    }
    
    /**
     * 알람이 중지 요청되었는지 확인
     */
    fun isStopRequested(alarmId: Int): Boolean {
        cleanExpiredEntries()
        return stoppedAlarms.containsKey(alarmId)
    }
    
    /**
     * 지정된 시간보다 오래된 항목 제거
     */
    private fun cleanExpiredEntries() {
        val currentTime = System.currentTimeMillis()
        val keysToRemove = stoppedAlarms.entries
            .filter { currentTime - it.value > EXPIRATION_TIME_MS }
            .map { it.key }
        
        for (key in keysToRemove) {
            stoppedAlarms.remove(key)
        }
    }
    
    /**
     * 알람을 중지 요청 목록에서 제거
     */
    fun clearStopRequest(alarmId: Int) {
        stoppedAlarms.remove(alarmId)
    }
} 