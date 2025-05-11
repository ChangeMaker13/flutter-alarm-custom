package com.gdelataillade.alarm.services

import com.gdelataillade.alarm.models.AlarmSettings

import android.content.Context
import io.flutter.Log
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.serialization.json.Json
import kotlinx.serialization.encodeToString

const val SHARED_PREFERENCES_NAME = "AlarmSharedPreferences"

private val Context.dataStore: DataStore<Preferences> by
preferencesDataStore(SHARED_PREFERENCES_NAME)

class AlarmStorage(context: Context) {
    companion object {
        private const val TAG = "AlarmStorage"
        private const val PREFIX = "__alarm_id__"
    }

    private val dataStore = context.dataStore

    fun saveAlarm(alarmSettings: AlarmSettings) {
        return runBlocking {
            val key = stringPreferencesKey("$PREFIX${alarmSettings.id}")
            val value = Json.encodeToString(alarmSettings)
            dataStore.edit { preferences -> preferences[key] = value }
        }
    }

    fun unsaveAlarm(id: Int) {
        return runBlocking {
            val key = stringPreferencesKey("$PREFIX$id")
            dataStore.edit { preferences -> preferences.remove(key) }
        }
    }

    fun getSavedAlarms(): List<AlarmSettings> {
        val alarms = mutableListOf<AlarmSettings>()

        return runBlocking {
            dataStore.data.map { preferences ->
                preferences.asMap().filter { it.key.name.startsWith(PREFIX) }
                    .mapNotNull {
                        try {
                            Json.decodeFromString<AlarmSettings>(it.value as String)
                        } catch (e: Exception) {
                            Log.e(TAG, "Error parsing alarm settings: ${e.message}")
                            null
                        }
                    }
            }.first()
        }
    }

    fun checkAlarmExists(id: Int): Boolean {
        return runBlocking {
            val key = stringPreferencesKey("$PREFIX$id")
            dataStore.data.map { preferences ->
                preferences.contains(key)
            }.first()
        }
    }
}
