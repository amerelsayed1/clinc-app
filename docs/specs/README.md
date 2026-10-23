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

Backend: Node.js (TypeScript, Fastify) + PostgreSQL. Clinic UI: React dashboard. Features are delivered as **vertical slices** (migration + API + dashboard + tests + spec status) one at a time.

## Implementation status

| Spec | Status |
|------|--------|
| 01 Identity & Auth | **Done except:** MFA for doctors (F01-3), email, patient claim flow (F01-7, needs spec 03), phone change (F01-8) |
| 02 Clinic & Staff | **Done** (F02-1…F02-6). Custom roles beyond per-permission denial are P1 |
| 03 Patients & Relationships | **Done except:** manual duplicate merge (F03-5, needs record tables from spec 05/06 first; detection + override warning is done), dependents (out of MVP). Patient-side API exists (claim, accept, decline, end); no patient UI yet |
| 04–10 | Not started |
| 11 Audit & Security | Audit log hash chain + append-only trigger done; remaining items arrive with their features |

## Cross-cutting rules

- Authorization is enforced **server-side** on role **and** care relationship **and** sharing grant. UI hiding is never sufficient.
- Every record carries `author_id`, `source` (`clinician` | `patient` | `staff`), `workspace_id`, `created_at`, `version`, `verification_status`.
- Signed clinical records are append-only; changes are amendments that reference the original.
- Data model uses `workspace_id` everywhere so multi-doctor clinics (future) need no migration of ownership; MVP UI exposes exactly one doctor per workspace.
- Push notifications never contain diagnosis or other sensitive content.
