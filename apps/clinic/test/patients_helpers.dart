import 'package:carelink_clinic/src/clinic_repository.dart';
import 'package:carelink_clinic/src/session.dart';
import 'package:clinic_core/clinic_core.dart';

import 'fake_api.dart';

/// FakeApi that also remembers the query of the last call per route.
class QueryApi extends FakeApi {
  QueryApi(super.routes);
  final Map<String, Map<String, String>?> lastQuery = {};

  @override
  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, bool auth = true}) {
    lastQuery['$method $path'] = query;
    return super.request(method, path, body: body, query: query, auth: auth);
  }
}

const nursePerms = ['patients.read', 'patients.write', 'appointments.read', 'vitals.write', 'documents.upload', 'documents.upload_clinical', 'clinical.read'];
const unverifiedDoctorPerms = ['patients.read', 'patients.write', 'appointments.read', 'appointments.manage', 'clinical.read', 'relationships.manage'];

Future<ClinicSession> clinicSession(FakeApi api, String role, List<String> perms, {Map<String, dynamic>? doctorProfile}) async {
  final auth = AuthController(api);
  api.routes['GET /me'] = (_) => me(member: membership(role, perms), doctorProfile: doctorProfile);
  await auth.bootstrap();
  return ClinicSession(auth: auth, repository: ClinicRepository(api), kit: NotificationsKit(api));
}

Map<String, dynamic> patientJson({String id = 'p1', String status = 'active', String name = 'Salma Ali', int number = 12, String phone = '+201001112222', String? dob = '1990-05-01', String? sex = 'female', bool hasAccount = false}) => {
      'id': id,
      'patientNumber': number,
      'fullName': name,
      'phone': phone,
      'dateOfBirth': dob,
      'sex': sex,
      'status': status,
      'hasAccount': hasAccount,
      'createdAt': '2026-01-01T10:00:00Z',
      'endedAt': null,
      'endedBy': null,
    };

Map<String, dynamic> encounterJson({
  String id = 'e1',
  String status = 'draft',
  int revision = 3,
  int version = 1,
  int? published,
  String authorId = 'u1',
  Map<String, dynamic>? content,
  List<Map<String, dynamic>> observations = const [],
  Map<String, dynamic>? versionMeta,
}) =>
    {
      'id': id,
      'patient': {'id': 'p1', 'fullName': 'Salma Ali', 'patientNumber': 12},
      'appointmentId': null,
      'author': {'id': authorId, 'fullName': 'Dr Test'},
      'encounterDate': '2026-10-24T09:00:00Z',
      'status': status,
      'revision': revision,
      'currentVersion': version,
      'signedAt': status == 'signed' ? '2026-10-24T09:30:00Z' : null,
      'publishedVersion': published,
      'publishedAt': null,
      'content': content ??
          {'chiefComplaint': 'Cough', 'history': 'Two days', 'diagnosis': '', 'plan': '', 'privateNotes': 'secret', 'prescriptions': <Map<String, dynamic>>[]},
      'version': versionMeta ?? {'version': version, 'authorName': 'Dr Test', 'createdAt': '2026-10-24T09:00:00Z', 'amendmentReason': null, 'changedFields': <String>[]},
      'observations': observations,
    };

Map<String, dynamic> obsJson(String id, {String kind = 'weight_kg', num value = 70, String by = 'u1', String role = 'doctor', bool voided = false}) => {
      'id': id,
      'kind': kind,
      'value': value,
      'unit': 'kg',
      'measuredAt': '2026-10-24T09:05:00Z',
      'recordedBy': by,
      'recordedByName': 'Someone',
      'recordedRole': role,
      'voided': voided,
      'voidReason': null,
    };

Map<String, dynamic> apptJson(String id, String status, {String name = 'Salma Ali', String at = '2026-10-24T08:00:00Z', String type = 'new', bool walkIn = false, String? reason, String? encounterId, String? checkedInAt}) => {
      'id': id,
      'patient': {'id': 'p1', 'fullName': name, 'patientNumber': 12, 'phone': '+201001112222'},
      'scheduledAt': at,
      'durationMinutes': 20,
      'type': type,
      'isWalkIn': walkIn,
      'reason': reason,
      'status': status,
      'checkedInAt': checkedInAt,
      'cancelReason': null,
      'encounterId': encounterId,
    };
