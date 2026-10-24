class SharedMarker {
  const SharedMarker({required this.via, required this.label, this.grantId, this.expiresAt, this.originClinic});
  final String via; // 'grant' | 'send'
  final String label;
  final String? grantId;
  final String? expiresAt;
  final String? originClinic;

  factory SharedMarker.fromJson(Map<String, dynamic> j) => SharedMarker(
        via: (j['via'] ?? 'send') as String,
        label: (j['label'] ?? 'Shared by patient') as String,
        grantId: j['grantId'] as String?,
        expiresAt: j['expiresAt'] as String?,
        originClinic: j['originClinic'] as String?,
      );
}

class TimelineEntry {
  const TimelineEntry({
    required this.type,
    required this.id,
    required this.date,
    required this.title,
    required this.summary,
    required this.badge,
    this.refType = '',
    this.authorName,
    this.sourceKind = 'clinic',
    this.sourceName,
    this.version = 1,
    this.amended = false,
    this.shared,
  });

  final String type;
  final String id;
  final String refType;
  final String date;
  final String title;
  final String summary;
  final String? authorName;
  final String sourceKind; // 'clinic' | 'patient'
  final String? sourceName;
  final int version;
  final bool amended;

  /// clinician_authored | patient_submitted | reviewed
  final String badge;
  final SharedMarker? shared;

  String get key => '$type:$id';

  factory TimelineEntry.fromJson(Map<String, dynamic> j) {
    final source = (j['source'] as Map?)?.cast<String, dynamic>() ?? const {};
    return TimelineEntry(
      type: (j['type'] ?? '') as String,
      id: j['id'] as String,
      refType: (j['refType'] ?? '') as String,
      date: (j['date'] ?? '') as String,
      title: (j['title'] ?? '') as String,
      summary: (j['summary'] ?? '') as String,
      authorName: (j['author'] as Map?)?['name'] as String?,
      sourceKind: (source['kind'] ?? 'clinic') as String,
      sourceName: source['name'] as String?,
      version: ((j['version'] ?? 1) as num).toInt(),
      amended: (j['amended'] ?? false) as bool,
      badge: (j['verificationBadge'] ?? 'clinician_authored') as String,
      shared: j['shared'] == null ? null : SharedMarker.fromJson((j['shared'] as Map).cast<String, dynamic>()),
    );
  }
}

class TimelinePage {
  const TimelinePage(this.items, this.nextCursor);
  final List<TimelineEntry> items;
  final String? nextCursor;
}

class TimelineFilters {
  const TimelineFilters({this.types = const {}, this.from, this.to, this.source = '', this.q = ''});
  final Set<String> types;
  final String? from; // yyyy-mm-dd
  final String? to;
  final String source; // '' | own | shared | patient
  final String q;

  bool get isEmpty => types.isEmpty && from == null && to == null && source.isEmpty && q.trim().isEmpty;

  TimelineFilters copyWith({Set<String>? types, Object? from = _keep, Object? to = _keep, String? source, String? q}) => TimelineFilters(
        types: types ?? this.types,
        from: identical(from, _keep) ? this.from : from as String?,
        to: identical(to, _keep) ? this.to : to as String?,
        source: source ?? this.source,
        q: q ?? this.q,
      );

  Map<String, String> toQuery({String? cursor, int limit = 30}) => {
        'limit': '$limit',
        if (types.isNotEmpty) 'type': (types.toList()..sort()).join(','),
        'from': ?from,
        'to': ?to,
        if (source.isNotEmpty) 'source': source,
        if (q.trim().isNotEmpty) 'q': q.trim(),
        'cursor': ?cursor,
      };
}

const _keep = Object();

const timelineTypes = <String, String>{
  'encounter': 'Consultations',
  'prescription': 'Prescriptions',
  'document': 'Documents',
  'observation': 'Vitals',
  'followup': 'Follow-up',
  'appointment': 'Appointments',
  'shared_notice': 'Sharing',
};
