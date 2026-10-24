import 'package:clinic_core/clinic_core.dart';

/// A record the patient can ask a clinic to correct.
class CorrectableRecord {
  const CorrectableRecord({required this.type, required this.id, required this.title, required this.subtitle});
  final String type; // encounter | document | relationship
  final String id;
  final String title;
  final String subtitle;
}

class CorrectionRequest {
  const CorrectionRequest({required this.id, required this.targetType, required this.description, required this.status, this.resolutionNote, this.clinicName, this.createdAt});

  factory CorrectionRequest.fromJson(Map<String, dynamic> j) => CorrectionRequest(
        id: j['id'] as String,
        targetType: j['targetType'] as String? ?? '',
        description: j['description'] as String? ?? '',
        status: j['status'] as String? ?? 'open',
        resolutionNote: j['resolutionNote'] as String?,
        clinicName: j['clinicName'] as String?,
        createdAt: parseApiDate(j['createdAt']),
      );

  final String id;
  final String targetType;
  final String description;
  final String status; // open | resolved | rejected
  final String? resolutionNote;
  final String? clinicName;
  final DateTime? createdAt;
}
