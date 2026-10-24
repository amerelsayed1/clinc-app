# 11 — Audit & Security (P0)

**Source:** BR-08, RULE-007, RULE-008. Legal review (Law 151/2020) is a **gate** before real patient data.

## Functional requirements
| ID | Requirement |
|----|-------------|
| F11-1 | Append-only, tamper-evident audit log (hash-chained entries): actor, role, workspace, action, target, scope, IP/device, timestamp, result. |
| F11-2 | Audited: all clinical record reads of sensitive scope, creates/amendments, sharing events, file downloads, permission changes, auth events, exports. |
| F11-3 | Doctors can view their workspace's log; patients can view access to their own data (spec 08); platform admins access via break-glass with justification, itself audited. |
| F11-4 | Encryption in transit (TLS 1.2+) and at rest; managed keys with rotation; secrets never in the repo. |
| F11-5 | Authorization policy layer: role × relationship × grant, deny by default, with automated tests for the permission matrix and cross-doctor isolation. |
| F11-6 | Backups with tested restore, defined RPO/RTO, and incident-response runbook. |
| F11-7 | Data subject operations: export, correction request, retention policy and legally mandated retention overrides. |
| F11-8 | Mobile hardening: secure token storage, optional biometric lock, screenshot/app-switcher masking for clinical screens, no PHI in logs or analytics. |
| F11-9 | Threat model completed for sharing links/QR before enabling external access (P1). |

## Acceptance criteria
- Tampering with an audit row is detectable by chain verification job.
- Security test suite proves RULE-003 (cross-doctor isolation) and RULE-005 (receptionist limits) on every endpoint.
- No real patient data enters any environment before the legal-review checkpoint is signed off.

---

## Implementation notes

Status: **API, dashboard, patient app and admin app implemented; infrastructure items and the legal-review gate remain open** (see "Not done").
Migration `010_security.sql`. Routes: `apps/api/src/routes/security.ts`, `admin.ts` (break-glass, verification), `workspaces.ts` (audit read/export). Ops: `docs/runbook.md`.

### F11-1 / F11-2 / F11-3 audit
- Entries now carry `result` (`success` | `denied`), `ip` and `device` (user agent, captured per request through `AsyncLocalStorage`, so no route has to pass them). `result` and `device` are part of the hash whenever they carry information, so rows written before migration 010 still verify and any later edit of either field is detected. Metadata is JSON-normalised before hashing (an `undefined` value used to hash differently from what jsonb stores and would have broken the chain; fixed with a regression test).
- Newly audited: patient record view, encounter list, vitals trend, document list and link issuance (`patient.viewed`, `patient.encounters_listed`, `patient.observations_viewed`, `patient.documents_listed`, `document.link_issued`) on top of the existing encounter/history/prescription/file reads, exports (`audit.exported`, `patient.exported`), permission changes (`member.updated`), sharing events, and auth events (login, failed login = `denied`, logout, MFA enrol/disable, phone change request and confirm, session revoke, refresh-token reuse). Auth events are written to the `global` chain **and mirrored into every workspace the user belongs to**, so a clinic owner sees staff sign-in/MFA/session activity. A refused permission check writes `access.denied` (result `denied`) to the clinic chain, at most once a minute per user/route/permission.
- `GET /workspace/audit` filters: `action` (exact, or prefix when it ends in `.`/`*`), `actor`, `targetType`, `targetId`, `result`, `from`/`to` (date or datetime), `before`/`limit`. `GET /workspace/audit/export` returns the same filter as a JSON document including `hash`/`prevHash` and the chain verdict; the export is itself audited.
- Verification: `verifyAllChains` runs hourly from `server.ts` (logs `AUDIT CHAIN BROKEN` at error level) and on demand via `GET /admin/audit/verify`; runs are stored (`audit_verifications`, `GET /admin/audit/verifications`).
- Break-glass: `POST /admin/break-glass {workspaceId, justification (>=15), minutes (1-60)}` -> `GET /admin/workspaces/:id/audit` works only while an unexpired, unrevoked grant of that admin exists. Grant, every read, revocation and every refused attempt are written to the **workspace's** chain (`breakglass.granted / audit_read / revoked / denied`); the dashboard shows them as highlighted rows with a banner. The admin must have MFA enabled (`mfa_required` otherwise). Admin routes also record `admin.denied` for non-admins.

### F11-4 platform hygiene
- Response headers set in an `onSend` hook (nosniff, frame-deny, no-referrer, COOP, restrictive CSP, `cache-control: no-store` unless a route sets its own, HSTS in production).
- `assertProductionConfig` refuses to boot production with default/short secrets, wrong-length key, dev DB credentials or `OTP_DEV_ECHO=true` (unit-tested). `trustProxy` is no longer hard-coded `true`: `X-Forwarded-For` is honoured only when `TRUST_PROXY` says so (it was spoofable: audit IPs and the new rate limit could be forged).
- `RateLimiter` interface + in-memory implementation; every `/auth/*` call is limited per IP (`AUTH_RATE_LIMIT_PER_MIN`, default 60), 429 with `retry-after`. Patient export limited per user per hour (database-backed).
- Pino logger configured with redaction of phone numbers, codes, tokens, names and clinical text, request bodies never logged, query strings dropped from logged URLs and signed `/files/<token>` links masked (tested against a captured log stream).
- Master-key versioning: wrapped keys are `<keyId>.<base64>`; `DOCUMENT_KEY_ID`, `DOCUMENT_ENCRYPTION_KEYS_OLD`, and `npm run rotate-keys -w @clinic/api` re-wrap file keys and TOTP secrets. Procedure in `docs/runbook.md`.

### F11-5 authorization matrix
`apps/api/test/permissions.test.ts` classifies every route (`ctx.app.routeTable`, filled by an `onRoute` hook). A route that is not in `MATRIX` fails the suite, as does a stale entry, so **new endpoints must be classified in the same change**. For each route it proves: no/invalid token -> 401; not a member, patient, platform admin, receptionist/nurse/unverified doctor without the permission -> 403; another clinic's doctor (RULE-003) or another patient presenting a foreign id -> 404; admin routes need an admin (and MFA for the strict ones). Dedicated RULE-005 tests cover the front desk (no clinical reads, administrative documents only, no clinical upload/consult/publish) and a nurse never sees private notes.
Authorization defects found and fixed while writing it:
1. `x-workspace-id` with a non-UUID value caused a 500 (invalid uuid cast); now 400.
2. List-by-patient endpoints (`GET /patients/:id/encounters`, `/observations`, `/documents`) answered `200 []` for another clinic's patient id instead of 404 (and would have written audit rows about foreign ids). They now return 404 like the rest.
3. `trustProxy: true` let clients forge their IP (audit trail, rate limit); see above.
4. The audit chain broke when any metadata value was `undefined` (e.g. doctor decision without a note); fixed in `writeAudit`.
5. Test harness `global-setup.ts` always dropped/created `clinic_test` regardless of `TEST_DATABASE_URL`, so concurrent suites collided; it now uses the configured database name.
Observed but left as designed: signed file links are bearer capabilities valid 10 minutes (anyone holding the URL can fetch the file; re-checked against live membership/grant); a clinic can still read its own retained records after a patient ends the relationship (retention); `/patient/grants` by doctor phone reveals whether a phone belongs to a verified doctor.

### F11-7 data-subject operations
- `POST /patient/export`: JSON bundle (`carelink-patient-export/1`) of own profile, relationships, published encounters with vitals, visible documents' metadata, grants, access log and correction requests; never private notes, history or administrative files. Audited (`patient.exported`), rate limited (3/hour/user), no file bytes (use the normal signed links).
- Correction requests: `POST /patient/correction-requests {targetType: encounter|document|relationship, targetId, description}` (the target must be a record the patient can see; one open request per record; max 10 open); clinic side `GET /correction-requests` (clinical.read), `POST /correction-requests/:id/resolve|reject {note}` (clinical.write). Deciding only changes the request; the record is never edited (verified in a test); a justified fix goes through the encounter amendment flow. The patient's free text is not copied into the audit log.
- Retention policy object `config.retention` (10 years clinical records/audit log, `legalHoldBlocksDeletion`) is exposed read-only at `GET /workspace/retention`. **Legal-retention override:** `PATCH /patients/:id/legal-hold {hold, reason}` (relationships.manage, i.e. the owner) sets a hold; while set, clinic document deletion returns `409 legal_hold`. Patient deletion of own uploads already refuses documents that were ever sent to a clinic (clinic may keep a lawful copy); records are tombstoned, never erased, in all other paths.

### F11-8 mobile hardening (packages/clinic_core `src/security`, used by patient and admin apps)
- Optional app lock: `AppLockController` + `AppLockGate` + `AppLockTile` using `local_auth` (biometrics with device-passcode fallback, behind a `DeviceAuthenticator` interface). Enabling or disabling requires authenticating; auto-locks when backgrounded (configurable grace period) and on cold start; locked content is not painted.
- App-switcher masking: `PrivacyShield` covers the app with an opaque blurred screen whenever the lifecycle is not `resumed` (iOS and Android). Screenshot blocking: `SecureScreen` toggles Android `FLAG_SECURE` through a small `carelink/secure_screen` channel implemented in each Android `MainActivity` (which now extends `FlutterFragmentActivity` as `local_auth` requires; `USE_BIOMETRIC` permission and `NSFaceIDUsageDescription` added). `secureAppBuilder` applies all three to **every route after sign-in** (not only the home screen), never to login screens.
- No PHI in logs: no `print`/`debugPrint` in any Dart code; tokens live in `flutter_secure_storage`.
- Patient app: Account > "Privacy and data": app lock switch, export my data (share sheet via `share_plus`, or copy), request a correction (pick a clinic record, describe the problem) and a list of requests with the clinic's reply. Admin app: new "Audit" tab (verify all chains, history) and "Break-glass" tab (clinic picker, justification, 15/30/60 minutes, active grants with revoke, read-only audit viewer); app lock switch on Account.
- Dashboard: Audit page with filters, JSON export, denied/break-glass highlighting and a banner when platform staff accessed the log; owner-only "Data requests" page (correction requests, retention and legal holds).

### Not done / still open
- **Legal-review gate (Law 151/2020) remains open**; `docs/runbook.md` lists the sign-off items. No real patient data may enter any environment until it is closed.
- Infrastructure, not code: TLS termination/scan, managed KMS or HSM for the master key (today an environment secret), database/object-store encryption at rest settings, **backup configuration and a tested restore drill** (RPO 15 min / RTO 4 h are unvalidated placeholders), alerting on `AUDIT CHAIN BROKEN`, a distributed rate-limit store for multi-instance deployments.
- F11-9 threat model for sharing links/QR (P1) is not written; external link sharing is not enabled.
- Not verified on a device or simulator: biometric prompts, `FLAG_SECURE`, iOS app-switcher snapshot and the share sheet were exercised only through unit/widget tests and an Android debug build of the patient app (the admin app shares the same Kotlin; its APK build was skipped when the disk filled).
- Correction request outcomes are not pushed to the patient (they see them in the app); notifications for them would be a spec 10 template addition.
- Patient-side audit view of clinic access to their data is the spec 08 access log; audit entries for the patient's own reads are not recorded.
