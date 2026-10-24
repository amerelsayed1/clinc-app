/// Day keys in the order the dashboard shows them (week starts Saturday).
const workingDays = <(String, String)>[
  ('sat', 'Saturday'),
  ('sun', 'Sunday'),
  ('mon', 'Monday'),
  ('tue', 'Tuesday'),
  ('wed', 'Wednesday'),
  ('thu', 'Thursday'),
  ('fri', 'Friday'),
];

class TimeRange {
  const TimeRange(this.start, this.end);
  factory TimeRange.fromJson(Map<String, dynamic> j) => TimeRange(j['start'] as String, j['end'] as String);
  final String start; // HH:MM
  final String end;
  Map<String, String> toJson() => {'start': start, 'end': end};
  TimeRange copyWith({String? start, String? end}) => TimeRange(start ?? this.start, end ?? this.end);
  bool get isValid => start.compareTo(end) < 0;
}

class ClinicSettings {
  const ClinicSettings({required this.timezone, required this.slotMinutes, required this.workingHours});

  factory ClinicSettings.fromJson(Map<String, dynamic> j) {
    final wh = (j['workingHours'] as Map<String, dynamic>? ?? const {});
    return ClinicSettings(
      timezone: j['timezone'] as String,
      slotMinutes: (j['slotMinutes'] as num).toInt(),
      workingHours: {
        for (final (key, _) in workingDays)
          key: [for (final r in (wh[key] as List? ?? const [])) TimeRange.fromJson(r as Map<String, dynamic>)],
      },
    );
  }

  final String timezone;
  final int slotMinutes;
  final Map<String, List<TimeRange>> workingHours;

  Map<String, dynamic> toJson() => {
        'timezone': timezone,
        'slotMinutes': slotMinutes,
        'workingHours': {for (final e in workingHours.entries) e.key: [for (final r in e.value) r.toJson()]},
      };

  ClinicSettings copyWith({String? timezone, int? slotMinutes, Map<String, List<TimeRange>>? workingHours}) =>
      ClinicSettings(timezone: timezone ?? this.timezone, slotMinutes: slotMinutes ?? this.slotMinutes, workingHours: workingHours ?? this.workingHours);

  /// Opens/closes a day (open = 09:00-17:00 like the dashboard) or edits its first range, keeping any extra ranges.
  ClinicSettings withDay(String day, {bool? open, String? start, String? end}) {
    final ranges = [...?workingHours[day]];
    if (open == false) {
      ranges.clear();
    } else if (open == true && ranges.isEmpty) {
      ranges.add(const TimeRange('09:00', '17:00'));
    } else if (ranges.isNotEmpty) {
      ranges[0] = ranges[0].copyWith(start: start, end: end);
    }
    return copyWith(workingHours: {...workingHours, day: ranges});
  }

  /// First problem that would make the server reject the settings, or null.
  String? validate() {
    if (timezone.trim().isEmpty) return 'Enter a time zone, e.g. Africa/Cairo';
    if (slotMinutes < 5 || slotMinutes > 120) return 'Appointment length must be between 5 and 120 minutes';
    for (final (key, label) in workingDays) {
      for (final r in workingHours[key] ?? const <TimeRange>[]) {
        if (!r.isValid) return '$label: opening time must be before closing time';
      }
    }
    return null;
  }
}
