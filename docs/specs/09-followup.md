# 09 — Follow-up Plans (P0, basic)

**Source:** BR-06. Advanced analytics are Phase 2.

## User stories
- As a doctor, I set a follow-up date and ask the patient to report specific measurements.
- As a patient, I get reminded and submit values or photos easily.
- As a doctor, I review submissions against earlier values.

## Functional requirements
| ID | Requirement |
|----|-------------|
| F09-1 | Follow-up plan: next-visit date, instructions, requested measurements (name, unit, frequency, optional normal range), end date. |
| F09-2 | Patient submissions: numeric value + time, optional note and attachment. |
| F09-3 | Submissions carry `source = patient`; UI never labels them as verified findings (BR-06). |
| F09-4 | Doctor dashboard: list of patients with overdue/missed submissions; simple trend chart per measurement. |
| F09-5 | Doctor can close or edit a plan; edits keep history. |
| F09-6 | Reminders follow patient notification preferences and consent (spec 10). |

## Acceptance criteria
- A submission after plan end is rejected or flagged.
- Out-of-range values are highlighted for the doctor only as "patient-reported, outside expected range" — no automatic clinical conclusion.

## Implementation notes

**Status:** F09-1…F09-5 done in API, dashboard and patient app. F09-6 (reminders honouring notification preferences/consent) is owned by spec 10; this feature only exposes the seam described below. Admin app: nothing needed (no admin-facing surface).

**Data (`008_followups.sql`):** `followup_plans` (per care relationship, `current_version`, `active|closed`), `followup_measurements` (known vital `kind` from `packages/shared` or a custom name; `daily|weekly|custom` frequency stored as `interval_days`; optional `normal_min/normal_max`; retired via `active=false`, never deleted), `followup_plan_versions` (immutable snapshot per create/edit/close, F09-5), `followup_submissions` (`source` check-constrained to `patient`, stored apart from clinician `observations`).

**API (`routes/followups.ts`):**
- Clinic: `POST /patients/:id/followups`, `GET /patients/:id/followups`, `GET|PATCH /followups/:id`, `POST /followups/:id/close`, `GET /followups/:id/history`, `GET /followups/:id/measurements/:mid/trend`, `GET /followups/attention`. Writes need `clinical.write` (verified doctor + MFA); reads need `clinical.read`, so receptionists get 403 on all plan content. Everything is scoped to the caller's workspace (other doctors get 404). PATCH accepts an optional `version` for optimistic concurrency.
- Patient: `GET /patient/followups`, `GET /patient/followups/due`, `POST /patient/followups/:id/submissions`, `GET /patient/followups/:id/submissions`. Only plans of the patient's own `active` relationships are visible.
- Submissions are rejected with 409 `plan_closed`, `plan_ended` (end date is inclusive, evaluated end-of-day in the clinic timezone) or `plan_not_started`. Known vital kinds also get the plausibility check from `VITAL_KINDS` (typo guard, not a clinical range); measured time may not be in the future or older than 90 days.
- `outsideExpectedRange` / `flagLabel` ("patient-reported, outside expected range") are computed at read time against the plan's current range and are only included in clinic responses. Patient responses contain neither the flag nor the range. Every submission is returned with `source: "patient"`, `verified: false`.
- Attachments reuse `POST /patient/documents` (category `other`); the submission references the document id and creates the revocable document share to that clinic so the doctor can open it through the existing document endpoints.
- Overdue logic: a measurement is due at `last submission + interval` (or at the plan start for the first reading) and counts as overdue (the "needs attention" list) one full day after that, only for active plans, active relationships and non-retired measurements.
- Audit: `followup.plan_created|plan_edited|plan_closed` (workspace, actor doctor) and `followup.submission_created` (actor patient). Metadata carries ids only, never measured values.

**Notification seam (spec 10):** `dueReminders(pool, now)` exported from `routes/followups.ts` returns `[{patientUserId, planId, measurementName, dueAt}]` for everything currently due for patients with an app account. It is stateless (no "already reminded" memory) and carries no clinical content; the notification service decides preference/consent filtering and de-duplication.

**Dashboard:** "Follow-up" section on the patient detail page (create/edit/close plan, per-measurement SVG trend chart with the expected range and flagged points, submissions table with the flag wording, edit-history list) and an "Attention" widget at the top of Appointments for users with `clinical.read`.

**Patient app:** "Follow-up" tab (due badge), plan page with instructions, what to report, own history, and a report form (value, time, note, optional photo via `image_picker`, uploaded through the patient document endpoint). `ApiClient.postMultipart` was added to `clinic_core` for this.

**Not done / caveats:** reminders themselves (spec 10); no device or simulator run of the patient app (widget tests with a fake API only, and the camera/gallery picker itself is not exercised); the dashboard has no component tests (typecheck and `vite build` only); advanced analytics are Phase 2.
