import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/foundation.dart';

import 'clinic_repository.dart';

/// Everything a feature needs to know about "who am I and where": the API client (already carrying the
/// `x-workspace-id` header), the signed-in [me], the active membership and its permissions.
///
/// `memberships[0]` is the active workspace (multi-clinic users are not supported yet). The session
/// listens to [auth], so [can] and friends always reflect the latest `GET /me` (call
/// `auth.reloadMe()` after changing roles/permissions).
class ClinicSession extends ChangeNotifier {
  ClinicSession({required this.auth, required this.repository, required this.kit}) {
    auth.addListener(_sync);
    _sync();
  }

  final AuthController auth;
  final ClinicRepository repository;
  final NotificationsKit kit;

  /// Id of the feature currently shown in the shell (null on the More list). Features that refresh
  /// when they become visible (e.g. the inbox) listen to this.
  final ValueNotifier<String?> selectedFeature = ValueNotifier(null);

  ApiClient get api => repository.api;
  Me? get me => auth.me;

  Map<String, dynamic>? get membership {
    final m = me?.memberships;
    return (m == null || m.isEmpty) ? null : m.first;
  }

  String? get workspaceId => membership?['workspaceId'] as String?;
  String? get workspaceName => membership?['workspaceName'] as String?;
  String? get role => membership?['role'] as String?;
  bool get isDoctor => role == 'doctor';
  Set<String> get permissions => ((membership?['permissions'] as List?) ?? const []).cast<String>().toSet();

  bool can(String permission) => permissions.contains(permission);
  bool canAll(Iterable<String> ps) => ps.every(can);

  void _sync() {
    final id = workspaceId;
    if (id == null) {
      api.extraHeaders.remove('x-workspace-id');
    } else {
      api.extraHeaders['x-workspace-id'] = id;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    auth.removeListener(_sync);
    selectedFeature.dispose();
    super.dispose();
  }
}
