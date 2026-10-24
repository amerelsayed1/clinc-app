# Feature Specifications (MVP)

Derived from the root [README.md](../../README.md) (BR-01…BR-08, RULE-001…RULE-010). Each spec has user stories, functional requirements, acceptance criteria, permissions, audit events and open questions.

Priority: **P0** = MVP, **P1** = Phase 2. IDs are `F<spec>-<n>`.

| # | Spec | BR / Rules | Priority |
|---|------|------------|----------|
| 01 | [Identity & Authentication](01-identity-auth.md) | BR-08 | P0 |
| 02 | [Clinic Workspace & Staff](02-clinic-staff.md) | BR-05, RULE-004/005/006/010 | P0 |
| 03 | [Patients & Care Relationships](03-patients-relationships.md) | BR-02, RULE-001/003 | P0 |
| 04 | [Appointments & Check-in](04-appointments.md) | BR-05.05 | P0 |
| 05 | [Encounters & Clinical Records](05-encounters.md) | BR-04, RULE-002/005/006 | P0 |
| 06 | [Documents & Prescription Capture](06-documents.md) | BR-01, BR-04, RULE-009 | P0 |
| 07 | [Medical Timeline](07-timeline.md) | BR-01 | P0 |
| 08 | [Sharing & Consent](08-sharing-consent.md) | BR-03, RULE-003/007 | P0 |
| 09 | [Follow-up Plans](09-followup.md) | BR-06 | P0 |
| 10 | [Notifications](10-notifications.md) | BR-07 | P0 |
| 11 | [Audit & Security](11-audit-security.md) | BR-08, RULE-008 | P0 |

## Stack and delivery approach

Backend: Node.js (TypeScript, Fastify) + PostgreSQL. Clinic UI: React dashboard. Mobile (Flutter): `apps/patient`, `apps/admin`, sharing `packages/clinic_core`. Features are delivered as **vertical slices across every app** (migration + API + dashboard + patient app + admin app + tests + spec status): a feature is not done until each app that needs it has it.

## Implementation status

| Spec | Status |
|------|--------|
| 01 Identity & Auth | **Done except:** email sign-up (optional), passwordless TOTP only (no SMS fallback factor), QR rendering of the authenticator key. Delivered across the dashboard, patient app and admin app together |
| 02 Clinic & Staff | **Done** (F02-1…F02-6). Custom roles beyond per-permission denial are P1 |
| 03 Patients & Relationships | **Done except:** manual duplicate merge (F03-5, needs record tables from spec 05/06 first; detection + override warning is done), dependents (out of MVP). Patient-side API exists (claim, accept, decline, end); no patient UI yet |
| 04 Appointments | **Done except:** reminders / cancellation notices (F04-7, spec 10) |
| 05 Encounters | **Done except:** coded diagnosis lists (P1), offline-tolerant entry beyond autosave-with-conflict-detection (F05-9) |
| 06 Documents | **Done except:** crop / auto-rotate in the capture UI (F06-1; images are only downscaled), a real malware scanner and S3-class storage (both are swappable interfaces with dev stand-ins), per-plan quotas (single placeholder limit until billing), patient UI (API only) |
| 07 Timeline | **Done** across API, dashboard and patient app (see notes in the spec) |
| 08 Sharing & Consent | **Done except:** external QR/link access for unregistered doctors (P1, F08-8/F11-9 threat model). Dashboard + patient app |
| 09 Follow-up | **Done except:** reminders depend on spec 10 wiring (done: source registered); advanced analytics are P2 |
| 10 Notifications | **Done except:** a real push provider (FCM/APNs) and web push; only new screens are localized ar/en |
| 11 Audit & Security | **Done in code** (permission matrix test, audit filters/export/break-glass, data export, correction requests, app lock). **Open:** TLS/KMS/backup drills (infrastructure), F11-9 threat model, legal-review gate |

## Cross-cutting rules

- Authorization is enforced **server-side** on role **and** care relationship **and** sharing grant. UI hiding is never sufficient.
- Every record carries `author_id`, `source` (`clinician` | `patient` | `staff`), `workspace_id`, `created_at`, `version`, `verification_status`.
- Signed clinical records are append-only; changes are amendments that reference the original.
- Data model uses `workspace_id` everywhere so multi-doctor clinics (future) need no migration of ownership; MVP UI exposes exactly one doctor per workspace.
- Push notifications never contain diagnosis or other sensitive content.
