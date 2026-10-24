import 'package:clinic_core/clinic_core.dart';

import 'team_models.dart';

/// Team endpoints (apps/api/src/routes/workspaces.ts). All but the list need `staff.manage`.
class TeamApi {
  TeamApi(this.api);
  final ApiClient api;

  Future<List<Member>> members() async =>
      ((await api.get('/workspace/members')) as List).cast<Map<String, dynamic>>().map(Member.fromJson).toList();

  Future<List<Invitation>> invitations() async =>
      ((await api.get('/workspace/invitations')) as List).cast<Map<String, dynamic>>().map(Invitation.fromJson).toList();

  Future<IssuedInvitation> invite({required String phone, required String role}) async =>
      IssuedInvitation.fromJson(await api.post('/workspace/invitations', body: {'phone': phone.trim(), 'role': role}) as Map<String, dynamic>);

  Future<void> revokeInvitation(String id) => api.delete('/workspace/invitations/$id');

  Future<void> setDenied(String memberId, List<String> denied) => api.patch('/workspace/members/$memberId', body: {'deniedPermissions': denied});

  Future<void> setStatus(String memberId, String status) => api.patch('/workspace/members/$memberId', body: {'status': status});

  Future<void> remove(String memberId) => api.delete('/workspace/members/$memberId');
}
