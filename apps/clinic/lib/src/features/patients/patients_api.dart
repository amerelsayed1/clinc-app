import 'package:clinic_core/clinic_core.dart';

import 'patients_models.dart';

/// Patient registry endpoints (apps/api/src/routes/patients.ts).
class PatientsApi {
  PatientsApi(this.api);
  final ApiClient api;

  Future<List<Patient>> list({String q = '', String status = 'open', int limit = 25, int offset = 0}) async {
    final res = await api.get('/patients', query: {
      'status': status,
      'limit': '$limit',
      if (offset > 0) 'offset': '$offset',
      if (q.trim().isNotEmpty) 'q': q.trim(),
    });
    return (res as List).cast<Map<String, dynamic>>().map(Patient.fromJson).toList();
  }

  Future<Patient> get(String id) async => Patient.fromJson(await api.get('/patients/$id') as Map<String, dynamic>);

  /// Throws [ApiException] with code `possible_duplicate` (409) unless [confirmNotDuplicate].
  Future<Patient> create({required String phone, required String fullName, String? dateOfBirth, String? sex, bool confirmNotDuplicate = false}) async {
    final res = await api.post('/patients', body: {
      'phone': phone.trim(),
      'fullName': fullName.trim(),
      'dateOfBirth': ?dateOfBirth,
      'sex': ?sex,
      if (confirmNotDuplicate) 'confirmNotDuplicate': true,
    });
    return Patient.fromJson(res as Map<String, dynamic>);
  }

  Future<Patient> update(String id, {required String fullName, String? dateOfBirth, String? sex}) async {
    final res = await api.patch('/patients/$id', body: {'fullName': fullName.trim(), 'dateOfBirth': dateOfBirth, 'sex': sex});
    return Patient.fromJson(res as Map<String, dynamic>);
  }

  Future<void> end(String id) => api.post('/patients/$id/end');
}
