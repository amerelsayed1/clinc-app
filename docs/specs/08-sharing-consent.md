# 08 — Sharing & Consent (P0)

**Source:** BR-03, RULE-003, RULE-007, Open Decisions 1 & 2.

## User stories
- As a patient, I choose which records Doctor B can see, for how long, and why.
- As a patient, I see who has access and revoke it.
- As a doctor, I request access to a patient's history held by another provider.

## Functional requirements
| ID | Requirement |
|----|-------------|
| F08-1 | A **grant** = patient → recipient (registered doctor/workspace) + scope + expiry + optional purpose. |
| F08-2 | Scope types: specific items, record categories, date range. Private notes excluded by design. |
| F08-3 | Two paths: patient-initiated share, and doctor-initiated **access request** the patient approves/denies. |
| F08-4 | Hybrid policy (recommended in README): standard categories can use time-scoped standing grants; designated sensitive categories require per-request approval. Sensitivity flags are configurable. |
| F08-5 | Default grant expiry (e.g. 30 days) with reminder before expiry; max duration enforced. |
| F08-6 | Revocation blocks future access immediately; already incorporated records in the recipient's chart are retained (RULE-007) — patient is told this at grant time. |
| F08-7 | Active-permissions screen for patients; access log showing who viewed what and when. |
| F08-8 | Recipients: registered clinicians at launch. QR / secure external link for unregistered doctors is P1 pending identity-verification design. |
| F08-9 | All access checks happen server-side per request against current grants. |

## Acceptance criteria
- Doctor B cannot read Doctor A's records before a grant, and cannot after expiry/revocation.
- Every view of a shared item creates an access-log entry visible to the patient.
- Grants cannot expand scope after creation; changes require a new grant.

## Audit events
grant created/expired/revoked, access request sent/approved/denied, shared item viewed.

## Implementation notes

**API** (`apps/api/src/routes/sharing.ts`, migration `007_sharing.sql`, tests in `test/sharing.test.ts`)
- Grants: `POST /patient/grants` (recipient = verified doctor by phone, or one of the patient's own clinics by `relationshipId`), `GET /patient/grants`, `DELETE /patient/grants/:id` (immediate revoke). Scope = specific items OR categories with an optional date range; grants are immutable, so changes need a new grant.
- Access requests: clinic side `POST /patients/:id/access-requests` (`clinical.write`; patient must be registered and actively connected), `GET /access-requests`, `DELETE /access-requests/:id`; patient side `GET /patient/access-requests`, `POST .../approve` (may narrow scope and shorten days, never widen: `scope_widened`), `POST .../deny`. Pending requests expire after 14 days.
- Shared-with-me (`clinical.read`): `GET /shared-with-me`, `/:id/items`, `/:id/encounters/:encId`, `/:id/documents/:docId`, signed page links. Every check is made server-side against the live grant; expired, revoked and unknown grants all return 404. Every view writes `shared_access_log` and an audit entry; the patient reads it with `GET /patient/access-log[?grantId=]`.
- F08-4 hybrid policy interpretation: the sensitivity list is configurable (`config.sharing.sensitiveCategories`, default `['encounters']`). A scope containing consultations (the category, or any specific encounter) is sensitive: duration capped at 14 days (`duration_too_long`) and an explicit `acknowledgeSensitive` is required, in addition to the always-required `acknowledgeRetention` (RULE-007, F08-6). Other categories may use standing grants of up to 90 days (default 30). Doctor-initiated requests are always per-request approval by the patient.
- Shareable items are only patient-visible documents (patient-uploaded, or clinic documents published to the patient; never `administrative`) and published encounter versions. Encounter `private_notes` and `history` are never shared.
- Reminders before expiry: grants carry an `expiresSoon` flag (within 3 days) used by the clients today; push/SMS reminders arrive with spec 10 (notifications, no PHI in text).

**Patient app** (`apps/patient`): new "Sharing" bottom-navigation tab with a badge of pending requests. Tabs: "Who can see" (active grants with clinic/doctor, scope summary, expiry, "Expires soon" badge, Revoke with confirmation that restates the retention rule, history of expired/revoked), "Requests" (inbox with clinic, purpose, scope, days, sensitive flag; Review opens an approve sheet that can only untick requested categories/items and shorten days, with the acknowledgements; Deny), "Activity" (access log, also filterable per grant). "Share records" opens the create form: clinic or doctor phone, items or categories (+ date range), 1-90 days (14 for sensitive), purpose, and mandatory acknowledgements. API error codes are mapped to plain wording (`shareErrorMessage`). Logic lives in `sharing_models.dart` and is unit-tested in `test/sharing_test.dart`.

**Dashboard** (`apps/dashboard`): patient detail page has "Request access to records held elsewhere" (shown for `clinical.write` on active relationships, with the registered-and-connected explanation) and this clinic's request list with status and Cancel (the list is workspace-wide because `GET /access-requests` returns no patient reference). New "Shared with me" nav entry (`clinical.read`): active grants, grant detail with items, shared encounter and shared document viewers (page images via the signed link). All shared views carry a "Shared by patient, provenance, expires <date>" banner plus a provenance badge (clinician-authored vs patient-submitted-unverified).

**Admin app**: no spec 08 surface (no natural place); not changed.

**Not verified**: no device/simulator run of the Flutter UI and no browser run of the dashboard pages (widget tests and a production build only).
