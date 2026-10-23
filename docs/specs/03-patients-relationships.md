# 03 — Patients & Care Relationships (P0)

**Source:** BR-02, RULE-001, RULE-003, Open Decision 5.

## User stories
- As a receptionist, I search for a patient by phone/name before creating a new one, to avoid duplicates.
- As a doctor, I invite a patient who isn't on the app yet.
- As a patient, I connect to several doctors and can end a relationship.

## Functional requirements
| ID | Requirement |
|----|-------------|
| F03-1 | One global patient identity; many `care_relationships` (patient ↔ workspace). |
| F03-2 | Search by phone (exact), name, and local patient number within the workspace; results show minimal identifying info only. |
| F03-3 | Registering a patient who matches an existing verified phone creates a **relationship request/link**, not a duplicate identity; the patient confirms via OTP/in-app prompt. |
| F03-4 | Unclaimed patient records (created by a doctor) are workspace-scoped until the patient claims them. |
| F03-5 | Duplicate suspicion (same name + DOB, different phone) raises a review flag; merges are manual, audited, reversible for a grace period, and never automatic. |
| F03-6 | Relationship states: `invited`, `active`, `ended`. Ended = no new access; retained records stay under the retention policy (RULE-007). |
| F03-7 | A doctor sees only records from their own relationship plus grants made under spec 08 (RULE-003). |
| F03-8 | Dependents/guardian profiles are out of MVP (Open Decision 3). |

## Acceptance criteria
- Two doctors treating one patient cannot see each other's encounters without a grant.
- Ending a relationship removes the doctor's access to patient-published and shared items going forward, but keeps their own authored records.
- Merge operation records who, when, and the pre-merge identifiers.

## Audit events
patient created, relationship invited/accepted/ended, duplicate flagged, merge executed/reverted.

## Implementation notes
- **Model:** `patients` is a minimal global identity (phone + optional linked account). Demographics live on the per-clinic `care_relationships` row, so two clinics registering the same phone get independent records and cannot see each other's data (RULE-003). Nothing is merged automatically.
- A patient who already has an account gets a relationship in `invited` state until they accept (F03-3); a patient without an account is `active` immediately and links on `POST /patient/claim` after phone OTP login (F01-7).
- Duplicate suspicion: same normalized name + date of birth, different phone, within one clinic -> `409 possible_duplicate`; resend with `confirmNotDuplicate: true` to proceed. Name matching is exact after case/space normalization, so spelling variants (including Arabic) are not caught yet.
- Registering a phone reveals to the registering clinic whether the patient has an account (`invited` vs `active`). Accepted for MVP; revisit with rate limits.
- Ending a relationship needs the `relationships.manage` permission (doctor only by default). The registration record is kept (retention); the clinic loses edit access and the patient leaves default search.
