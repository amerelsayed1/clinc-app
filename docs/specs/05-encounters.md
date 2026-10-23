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

## Implementation notes
- **Versioned content:** clinical text and the prescription live in `encounter_versions`. A draft edits version 1 in place; once signed, a database trigger rejects any update or delete of a version, so even direct SQL cannot rewrite history. Amendments insert version N+1 with a required reason and the list of changed fields; the original stays readable through `GET /encounters/:id/versions`.
- **Roles:** creating, editing, signing, amending, publishing and printing need `clinical.write` / `clinical.read` and, for edits, being the author. Nurses (`clinical.read`) can read an encounter and add vitals but never see `privateNotes` (omitted from the response in every version); receptionists have no access. An unverified doctor cannot create encounters.
- **Autosave (F05-9):** `PATCH /encounters/:id` requires the `revision` the client last saw. A stale revision returns `409 revision_conflict` with the current content, so two windows cannot silently overwrite each other (tested with 10 concurrent saves: exactly one wins). Autosaves are not audited; create, sign, amend, discard, publish, observations and every read of an encounter or its history are.
- **Vitals (F05-3):** separate `observations` rows attributed to the recorder and their role. Values are only plausibility-checked (e.g. 700 kg rejected), not judged clinically. Mistakes are voided with a reason, never edited, and voided rows stay on record. Vitals can only be added or voided while the encounter is a draft; a nurse can void only their own entries, the doctor any.
- **Trend (F05-8):** `GET /patients/:id/observations?kind=` returns non-voided points across this clinic's encounters only.
- **Publishing (F05-10):** a signed version is published explicitly. The patient sees chief complaint, diagnosis, plan, prescription and non-voided vitals of the published version, never `history` or `privateNotes`. After an amendment the patient keeps seeing the previously published version until the doctor republishes. Patients keep access to what was published to them even if the clinic relationship ends.
- **Prescription (F05-7):** `GET /encounters/:id/prescription` returns a print-ready payload (clinic, doctor licence, patient, items) for signed encounters; the dashboard has a print layout.
- **F04-6:** starting a consultation from an appointment creates the draft encounter (author = the doctor who started it) in the same transaction. Discarding it lets a new one be created for the same appointment.
- **Audit:** metadata holds ids, versions and field names only, never clinical text.
