# CareLink clinic app

Flutter app for the clinic team (doctor, nurse, receptionist), mobile-first. Mirrors `apps/dashboard`, shares auth, API client,
security screens, app lock and notifications with the other apps via `packages/clinic_core`.

## Run

```bash
flutter pub get
flutter run --dart-define=API_BASE_URL=http://localhost:3055   # local API port in this repo's dev setup
```

- Android emulator: `--dart-define=API_BASE_URL=http://10.0.2.2:3055`
- Web: `flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:3055` (the API must allow CORS for the web origin)
- Start the API with `OTP_DEV_ECHO=true` to see the sign-in code on screen.

## Checks

```bash
flutter analyze && flutter test
flutter build web --no-pub
```

## Structure

- `lib/src/app.dart` - MaterialApp, locale, secure app builder (app lock), `AuthGate`.
- `lib/src/clinic_root.dart` - gating (MFA enrolment, onboarding) and the permission-driven shell (bottom bar + More, licence banner).
- `lib/src/session.dart` - `ClinicSession`: api (with `x-workspace-id`), `me`, active membership, `can(permission)`, notifications kit.
- `lib/src/feature.dart` - `ClinicFeature`, `FeatureRegistry`, `NavLayout`, `ComingSoon`.
- `lib/src/features.dart` - the central registry (one `registerXxx` per feature).
- `lib/src/features/<name>/<name>_feature.dart` - one folder per feature; placeholders show "Coming soon" until replaced.

## Adding a feature

Replace the contents of `lib/src/features/<name>/<name>_feature.dart` (keep the `registerXxx` name and the feature id), put the screens,
models and API class in the same folder, and use `session.api` / `session.can(...)`. `features.dart` needs no change for the pre-registered
features; a brand-new one needs one import and one line in `featureRegistrars`.
