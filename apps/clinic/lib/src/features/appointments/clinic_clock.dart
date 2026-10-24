import 'package:clinic_core/clinic_core.dart';
import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Formats instants in the clinic's own time zone (like the dashboard's time.ts), not the phone's.
class ClinicClock {
  ClinicClock([String zone = fallbackZone]) : zone = zone, _loc = _resolve(zone);

  static const fallbackZone = 'Africa/Cairo';
  static bool _ready = false;

  final String zone;
  final tz.Location _loc;

  static tz.Location _resolve(String zone) {
    if (!_ready) {
      tzdata.initializeTimeZones();
      _ready = true;
    }
    try {
      return tz.getLocation(zone);
    } catch (_) {
      return tz.getLocation(fallbackZone);
    }
  }

  /// Reads the clinic's time zone from the workspace settings; falls back to Africa/Cairo on any failure.
  static Future<ClinicClock> load(ApiClient api) async {
    try {
      final s = await api.get('/workspace/settings');
      final zone = s is Map ? s['timezone'] : null;
      return ClinicClock(zone is String ? zone : fallbackZone);
    } catch (_) {
      return ClinicClock();
    }
  }

  DateTime at(DateTime instant) => tz.TZDateTime.from(instant, _loc);

  /// `YYYY-MM-DD` of [instant] in the clinic zone.
  String date(DateTime instant) => formatDate(at(instant));

  String today() => date(DateTime.now());

  String time(DateTime instant) {
    final d = at(instant);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  String dateTime(DateTime? instant) => instant == null ? '' : '${date(instant)} ${time(instant)}';
}
