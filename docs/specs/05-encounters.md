# 05 — Encounters & Clinical Records (P0)

**Source:** BR-04, RULE-002, 005, 006.

## User stories
- As a doctor, I document complaint, observations, diagnosis and plan quickly, with minimal typing.
- As a doctor, I correct a signed note without erasing history.
- As a nurse, I add vitals to the current encounter.

## Functional requirements
| ID | Requirement |
|----|-------------|
| F05-1 | Encounter fields: date, chief complaint, history, observations/vitals, diagnosis (free text, coded list = P1), plan, private notes, linked documents. |
| F05-2 | Private/internal notes are flagged and **never** included in sharing scopes or patient view. |
| F05-3 | Nurse-entered vitals are stored as separate observations attributed to the nurse and visible inside the encounter. |
| F05-4 | Lifecycle: `draft → signed`. Drafts are editable by author; signing locks the record. |
| F05-5 | Post-signature changes create an **amendment** (new version, reason required, original preserved and viewable). |
| F05-6 | Only doctors can add diagnoses or prescriptions; server rejects other roles (RULE-005/006). |
| F05-7 | Prescription entry: medication, dose, frequency, duration, notes; printable/shareable output. Photo-only prescription capture is spec 06. |
| F05-8 | Vitals trend comparison across encounters (weight, BP, glucose, etc.) for the same patient within the doctor's visible scope. |
| F05-9 | Autosave drafts and offline-tolerant entry with conflict-safe sync. |
| F05-10 | Doctor chooses what is **published** to the patient (encounter summary, prescription). Unpublished items are not visible to the patient. |

## Acceptance criteria
- Editing a signed encounter via API without the amendment flow is rejected.
- Version history shows author, timestamp, reason, and diff for every amendment.
- A published prescription appears in the patient timeline with clinician provenance.

## Audit events
encounter created/signed/amended, prescription created, publish/unpublish.
