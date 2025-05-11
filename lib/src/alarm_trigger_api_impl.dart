import 'package:alarm/alarm.dart';
import 'package:alarm/src/generated/platform_bindings.g.dart';
import 'package:logging/logging.dart';

/// Callback that is called when an alarm starts ringing.
typedef AlarmRangCallback = void Function(AlarmSettings alarm);

/// Callback that is called when an alarm is stopped.
typedef AlarmStoppedCallback = void Function(int alarmId);

/// Implements the API that handles calls coming from the host platform.
class AlarmTriggerApiImpl extends AlarmTriggerApi {
  AlarmTriggerApiImpl._({
    required AlarmRangCallback alarmRang,
    required AlarmStoppedCallback alarmStopped,
  })  : _alarmRang = alarmRang,
        _alarmStopped = alarmStopped,
        super() {
    AlarmTriggerApi.setUp(this);
  }

  static final _log = Logger('AlarmTriggerApiImpl');

  /// Cached instance of [AlarmTriggerApiImpl]
  static AlarmTriggerApiImpl? _instance;

  /// 최근에 중지 요청된 알람 ID 추적
  /// 경쟁 상태(Race Condition) 방지를 위한 메모리 내 캐시
  static final _recentlyStopped = <int, DateTime>{};

  /// 알람 ID가 최근에 중지 요청되었는지 확인
  static bool _wasRecentlyStopped(int alarmId) {
    final stoppedTime = _recentlyStopped[alarmId];
    if (stoppedTime == null) return false;

    // 5초 이내에 중지된 알람인지 확인
    final now = DateTime.now();
    final diff = now.difference(stoppedTime).inSeconds;

    // 5초 이상 지난 기록은 삭제
    if (diff > 5) {
      _recentlyStopped.remove(alarmId);
      return false;
    }

    return true;
  }

  /// 알람 중지 요청 기록
  static void _markAsStopped(int alarmId) {
    _recentlyStopped[alarmId] = DateTime.now();

    // 오래된 항목 정리
    _cleanupStoppedCache();
  }

  /// 오래된 중지 기록 정리
  static void _cleanupStoppedCache() {
    final now = DateTime.now();
    final idsToRemove = <int>[];

    for (final entry in _recentlyStopped.entries) {
      if (now.difference(entry.value).inSeconds > 10) {
        idsToRemove.add(entry.key);
      }
    }

    for (final id in idsToRemove) {
      _recentlyStopped.remove(id);
    }
  }

  final AlarmRangCallback _alarmRang;

  final AlarmStoppedCallback _alarmStopped;

  /// Ensures that this Dart isolate is listening for method calls that may come
  /// from the host platform.
  static void ensureInitialized({
    required AlarmRangCallback alarmRang,
    required AlarmStoppedCallback alarmStopped,
  }) {
    _instance ??= AlarmTriggerApiImpl._(
      alarmRang: alarmRang,
      alarmStopped: alarmStopped,
    );
  }

  @override
  Future<void> alarmRang(int alarmId) async {
    // 알람이 최근에 중지 요청되었는지 확인
    if (_wasRecentlyStopped(alarmId) || Alarm.isRecentlyStopped(alarmId)) {
      _log.info(
          'Alarm with id $alarmId was recently stopped. Ignoring ring request.');
      return;
    }

    final settings = await Alarm.getAlarm(alarmId);
    if (settings == null) {
      _log.warning('Alarm with id $alarmId started ringing but the settings '
          'object could not be found. This might happen if the alarm was stopped '
          'at the same time it started ringing. Stopping this alarm.');

      // 설정을 찾을 수 없는 경우 알람이 이미 중지되었을 수 있으므로 추가 조치 없이 종료
      return;
    }
    _log.info('Alarm with id $alarmId started ringing.');
    _alarmRang(settings);
  }

  @override
  Future<void> alarmStopped(int alarmId) async {
    // 알람 중지 추적
    _markAsStopped(alarmId);

    _log.info('Alarm with id $alarmId stopped.');
    _alarmStopped(alarmId);
  }
}
