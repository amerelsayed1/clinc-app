import 'package:clinic_core/clinic_core.dart';

/// "1.2 MB" / "340 KB".
String formatBytes(int n) {
  if (n < 1024 * 1024) return '${(n / 1024).round().clamp(1, 1 << 30)} KB';
  final mb = n / 1024 / 1024;
  return '${mb.toStringAsFixed(n > 10 * 1024 * 1024 ? 0 : 1)} MB';
}

/// ISO timestamp -> "2026-03-04 14:30" in the device's time zone ("" when null/invalid).
String formatTs(Object? iso) {
  if (iso is! String) return '';
  final d = DateTime.tryParse(iso);
  return d == null ? '' : formatDateTime(d.toLocal());
}

/// ISO date or timestamp -> "2026-03-04".
String formatDay(Object? iso) {
  if (iso is! String) return '';
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  return iso.length <= 10 ? iso : formatDate(d.toLocal());
}
