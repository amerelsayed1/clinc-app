import 'package:clinic_core/clinic_core.dart';

/// Record categories the API accepts in a scope (see apps/api/src/routes/sharing.ts).
const shareCategories = ['encounters', 'prescription', 'lab_result', 'imaging', 'report', 'other'];

/// Categories that are sensitive: capped at [sensitiveMaxDays] and need an explicit acknowledgement (F08-4).
const sensitiveCategories = ['encounters'];
const defaultShareDays = 30;
const maxShareDays = 90;
const sensitiveMaxDays = 14;

String categoryLabel(String c) => switch (c) {
      'encounters' => 'Consultations',
      'prescription' => 'Prescriptions',
      'lab_result' => 'Lab results',
      'imaging' => 'Imaging',
      'report' => 'Reports',
      'other' => 'Other documents',
      _ => c,
    };

class ItemRef {
  const ItemRef(this.type, this.id);
  final String type; // document | encounter
  final String id;
  Map<String, dynamic> toJson() => {'type': type, 'id': id};
  @override
  bool operator ==(Object other) => other is ItemRef && other.type == type && other.id == id;
  @override
  int get hashCode => Object.hash(type, id);
}

/// An item the patient can share (GET /patient/shareable).
class ShareableItem {
  const ShareableItem({required this.type, required this.id, required this.category, required this.date, required this.title, required this.source, this.clinicName});
  factory ShareableItem.fromJson(Map<String, dynamic> j) => ShareableItem(
        type: j['type'] as String,
        id: j['id'] as String,
        category: j['category'] as String,
        date: j['date'] as String,
        title: j['title'] as String? ?? '',
        source: j['source'] as String? ?? 'clinician',
        clinicName: j['clinicName'] as String?,
      );
  final String type, id, category, date, title, source;
  final String? clinicName;
  ItemRef get ref => ItemRef(type, id);
}

/// What a grant or request covers: specific items OR categories (+ optional date range).
class ShareScope {
  const ShareScope({this.items, this.categories, this.from, this.to});
  factory ShareScope.fromJson(Map<String, dynamic> j) => ShareScope(
        items: (j['items'] as List?)?.map((e) => ItemRef(e['type'] as String, e['id'] as String)).toList(),
        categories: (j['categories'] as List?)?.cast<String>(),
        from: j['from'] as String?,
        to: j['to'] as String?,
      );
  final List<ItemRef>? items;
  final List<String>? categories;
  final String? from, to;

  bool get isItems => items != null;

  Map<String, dynamic> toJson() => {
        if (items != null) 'items': items!.map((i) => i.toJson()).toList(),
        if (categories != null) 'categories': categories,
        if (from != null) 'from': from,
        if (to != null) 'to': to,
      };

  /// Sensitive when it includes consultations (mirrors the API's `isSensitive`).
  bool get sensitive => items != null ? items!.any((i) => i.type == 'encounter') : (categories ?? const []).any(sensitiveCategories.contains);

  String get summary {
    if (items != null) return '${items!.length} selected ${items!.length == 1 ? 'record' : 'records'}';
    final cats = (categories ?? const []).map(categoryLabel).join(', ');
    final range = from != null || to != null ? ' (${from ?? 'any'} to ${to ?? 'any'})' : '';
    return '$cats$range';
  }
}

/// Builds the scope for a new share from the form state; null when nothing valid is chosen.
ShareScope? buildScope({required bool byItems, Set<ItemRef> items = const {}, Set<String> categories = const {}, String? from, String? to}) {
  if (byItems) return items.isEmpty ? null : ShareScope(items: items.toList());
  if (categories.isEmpty) return null;
  // Keep the canonical category order so the payload is stable.
  return ShareScope(categories: shareCategories.where(categories.contains).toList(), from: from, to: to);
}

int maxDaysFor(ShareScope? scope) => scope != null && scope.sensitive ? sensitiveMaxDays : maxShareDays;

/// Returns a user-facing problem with the form, or null when it can be submitted.
String? validateShare({required ShareScope? scope, required int days, required bool hasRecipient, required bool ackRetention, required bool ackSensitive}) {
  if (!hasRecipient) return 'Choose who to share with.';
  if (scope == null) return 'Choose what to share.';
  if (scope.from != null && scope.to != null && scope.from!.compareTo(scope.to!) > 0) return 'The start date must be before the end date.';
  if (days < 1 || days > maxDaysFor(scope)) return 'Choose between 1 and ${maxDaysFor(scope)} days.';
  if (scope.sensitive && !ackSensitive) return 'Confirm that you want to share consultation records.';
  if (!ackRetention) return 'Please acknowledge how revoking works before sharing.';
  return null;
}

/// Maps an API failure from creating/approving a share to wording a patient understands.
String shareErrorMessage(Object e) {
  if (e is ApiException) {
    switch (e.code) {
      case 'retention_ack_required':
        return 'Please acknowledge that records a clinic has already added to its chart are kept after you revoke access.';
      case 'sensitive_ack_required':
        return 'Consultation records are sensitive. Please confirm you want to share them.';
      case 'duration_too_long':
        return 'Consultation records can be shared for at most $sensitiveMaxDays days at a time.';
      case 'invalid_scope':
        return 'One or more of the selected records can no longer be shared. Refresh and choose again.';
      case 'scope_widened':
        return 'You can only narrow what the doctor asked for, not add to it.';
      case 'invalid_state':
        return 'This request was already answered or has expired.';
    }
    if (e.status == 404) return 'No verified doctor was found for that recipient.';
  }
  return errorMessage(e);
}

class GrantRecipient {
  const GrantRecipient({this.clinicName, this.doctorName});
  final String? clinicName, doctorName;
  String get label => [?doctorName, ?clinicName].join(' - ');
}

class Grant {
  const Grant({required this.id, required this.scope, required this.purpose, required this.expiresAt, required this.status, required this.expiresSoon, required this.recipient, this.createdAt, this.revokedAt});
  factory Grant.fromJson(Map<String, dynamic> j) {
    final r = (j['recipient'] as Map?) ?? const {};
    return Grant(
      id: j['id'] as String,
      scope: ShareScope.fromJson(j['scope'] as Map<String, dynamic>),
      purpose: j['purpose'] as String? ?? '',
      createdAt: parseApiDate(j['createdAt']),
      expiresAt: parseApiDate(j['expiresAt']),
      revokedAt: parseApiDate(j['revokedAt']),
      status: j['status'] as String,
      expiresSoon: j['expiresSoon'] == true,
      recipient: GrantRecipient(clinicName: r['clinicName'] as String?, doctorName: r['doctorName'] as String?),
    );
  }
  final String id, purpose, status; // status: active | expired | revoked
  final ShareScope scope;
  final DateTime? createdAt, expiresAt, revokedAt;
  final bool expiresSoon;
  final GrantRecipient recipient;
  bool get isActive => status == 'active';
}

class AccessRequest {
  const AccessRequest({required this.id, required this.status, required this.scope, required this.purpose, required this.requestedDays, required this.sensitive, this.clinicName, this.doctorName, this.createdAt, this.expiresAt});
  factory AccessRequest.fromJson(Map<String, dynamic> j) => AccessRequest(
        id: j['id'] as String,
        status: j['status'] as String,
        scope: ShareScope.fromJson(j['scope'] as Map<String, dynamic>),
        purpose: j['purpose'] as String? ?? '',
        requestedDays: j['requestedDays'] as int? ?? defaultShareDays,
        sensitive: j['sensitive'] == true,
        clinicName: j['clinicName'] as String?,
        doctorName: j['doctorName'] as String?,
        createdAt: parseApiDate(j['createdAt']),
        expiresAt: parseApiDate(j['expiresAt']),
      );
  final String id, status, purpose;
  final ShareScope scope;
  final int requestedDays;
  final bool sensitive;
  final String? clinicName, doctorName;
  final DateTime? createdAt, expiresAt;
  bool get isPending => status == 'pending' && (expiresAt == null || expiresAt!.isAfter(DateTime.now()));
}

class AccessLogEntry {
  const AccessLogEntry({required this.id, required this.grantId, required this.itemType, this.itemTitle, this.clinicName, this.viewerName, this.at});
  factory AccessLogEntry.fromJson(Map<String, dynamic> j) => AccessLogEntry(
        id: j['id'] as String,
        grantId: j['grantId'] as String,
        itemType: j['itemType'] as String,
        itemTitle: j['itemTitle'] as String?,
        clinicName: j['clinicName'] as String?,
        viewerName: j['viewerName'] as String?,
        at: parseApiDate(j['at']),
      );
  final String id, grantId, itemType;
  final String? itemTitle, clinicName, viewerName;
  final DateTime? at;
}

/// State of the "approve a request" sheet. Only ever narrows the request (F08-2).
class ApprovalDraft {
  ApprovalDraft(this.request)
      : categories = {...?request.scope.categories},
        items = {...?request.scope.items},
        days = request.requestedDays;
  final AccessRequest request;
  Set<String> categories;
  Set<ItemRef> items;
  int days;

  /// Categories/items the patient may toggle: exactly what was requested, nothing more.
  List<String> get offeredCategories => request.scope.categories ?? const [];
  List<ItemRef> get offeredItems => request.scope.items ?? const [];

  bool get narrowed => request.scope.isItems ? items.length != offeredItems.length : categories.length != offeredCategories.length;

  ShareScope? get effectiveScope => request.scope.isItems
      ? (items.isEmpty ? null : ShareScope(items: offeredItems.where(items.contains).toList()))
      : (categories.isEmpty ? null : ShareScope(categories: offeredCategories.where(categories.contains).toList(), from: request.scope.from, to: request.scope.to));

  int get maxDays => (effectiveScope?.sensitive ?? request.sensitive) ? (request.requestedDays < sensitiveMaxDays ? request.requestedDays : sensitiveMaxDays) : request.requestedDays;

  void setDays(int d) => days = d.clamp(1, maxDays);

  /// Body for POST /patient/access-requests/:id/approve. `scope` is only sent when narrowed.
  Map<String, dynamic> body({required bool ackRetention, required bool ackSensitive}) {
    final d = days > maxDays ? maxDays : days;
    return {
      'days': d,
      if (narrowed && effectiveScope != null) 'scope': effectiveScope!.toJson(),
      'acknowledgeRetention': ackRetention,
      if (effectiveScope?.sensitive ?? false) 'acknowledgeSensitive': ackSensitive,
    };
  }

  String? validate({required bool ackRetention, required bool ackSensitive}) {
    final s = effectiveScope;
    if (s == null) return 'Select at least one thing to share, or deny the request.';
    if (s.sensitive && !ackSensitive) return 'Confirm that you want to share consultation records.';
    if (!ackRetention) return 'Please acknowledge how revoking works before approving.';
    return null;
  }
}

/// Number of requests still awaiting an answer (for the navigation badge).
int pendingCount(List<AccessRequest> r) => r.where((e) => e.isPending).length;
