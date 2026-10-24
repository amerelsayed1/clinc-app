# CareLink patient app

Flutter app (patients, mobile-first). Shares auth, API client and security screens with the other app via `packages/clinic_core`.

## Run

```bash
flutter pub get
flutter run --dart-define=API_BASE_URL=http://localhost:3000
```

- Android emulator: `--dart-define=API_BASE_URL=http://10.0.2.2:3000`
- Web: `flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:3000` (the API must allow CORS for the web origin)
- Start the API with `OTP_DEV_ECHO=true` to see the sign-in code on screen during development.

## Checks

```bash
flutter analyze && flutter test
flutter build web --no-pub
```

