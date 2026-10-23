# 07 — Medical Timeline (P0)

**Source:** BR-01.

## User stories
- As a doctor, I see one chronological view of everything I'm allowed to see for this patient.
- As a patient, I see my whole history across doctors, with clear labels on who produced what.

## Functional requirements
| ID | Requirement |
|----|-------------|
| F07-1 | Entry types: encounter, prescription, document, observation, follow-up event, appointment, shared-record notice. |
| F07-2 | Each entry shows author, workspace/source, date, version, verification badge (clinician-authored / patient-submitted / reviewed). |
| F07-3 | Filters: type, date range, source, doctor. Search by text on titles/notes within permitted scope. |
| F07-4 | **Doctor view** = own-relationship records + records shared to them (spec 08), each visually marked "shared by …". |
| F07-5 | **Patient view** = patient uploads + everything doctors published to them; private notes are excluded. |
| F07-6 | Amended records show a version indicator and link to history. |
| F07-7 | Pagination and lazy loading; usable with 1,000+ entries. |

## Acceptance criteria
- The same query run as two different doctors returns different entries for the same patient according to relationship and grants.
- Revoked shares disappear from the recipient's timeline for future views.
