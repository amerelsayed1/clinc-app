import 'feature.dart';
import 'features/account/account_feature.dart';
import 'features/appointments/appointments_feature.dart';
import 'features/audit/audit_feature.dart';
import 'features/data_requests/data_requests_feature.dart';
import 'features/notifications/notifications_feature.dart';
import 'features/patients/patients_feature.dart';
import 'features/settings/settings_feature.dart';
import 'features/shared_with_me/shared_with_me_feature.dart';
import 'features/team/team_feature.dart';

/// THE central registry of the clinic app's screens. One line per feature.
///
/// Each feature owns `features/<name>/<name>_feature.dart`, which exposes a
/// `void registerXxx(FeatureRegistry)` that adds its [ClinicFeature]. Every entry below already points
/// at such a file (unbuilt ones are placeholders showing "Coming soon"): to implement a feature, just
/// replace the contents of its own file - this list does not need to change. A brand-new feature
/// needs one import and one line here.
const List<FeatureRegistrar> featureRegistrars = [
  registerAppointments,
  registerPatients, // incl. encounters, documents, timeline, follow-up, sharing request (inside patient detail)
  registerNotifications,
  registerSharedWithMe,
  registerTeam,
  registerSettings,
  registerAudit,
  registerDataRequests,
  registerAccount, // profile, security (MFA/sessions/phone), app lock, notification preferences, sign out
];

FeatureRegistry buildFeatureRegistry([List<FeatureRegistrar> registrars = featureRegistrars]) {
  final registry = FeatureRegistry();
  for (final r in registrars) {
    r(registry);
  }
  return registry;
}
