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
