import 'package:clinic_core/clinic_core.dart';

/// Endpoints shared by the shell (onboarding, workspace). Feature-specific endpoints live next to
/// their feature (e.g. `features/team/team_api.dart`) and take [api] from the [ClinicSession].
class ClinicRepository {
  ClinicRepository(this.api);
  final ApiClient api;

  /// First-time doctor: creates the doctor profile (pending licence verification).
  Future<void> registerDoctor({required String fullName, required String licenseNumber}) =>
      api.post('/doctors/register', body: {'fullName': fullName.trim(), 'licenseNumber': licenseNumber.trim()});

  Future<void> createWorkspace({String? name}) =>
      api.post('/workspaces', body: (name == null || name.trim().isEmpty) ? <String, dynamic>{} : {'name': name.trim()});

  /// Joins a clinic with the one-time code a doctor sent by SMS.
  Future<void> acceptInvitation(String code) => api.post('/invitations/accept', body: {'code': code.trim()});
}
