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

## Implementation notes

**Status:** implemented (API, dashboard, patient app). Admin app: nothing, the timeline is a clinician/patient surface.

**API** (`apps/api/src/routes/timeline.ts`, no new tables or migration):
- `GET /patients/:relationshipId/timeline` (needs `clinical.read`; receptionists get 403, an unknown or other clinic's relationship is 404) and `GET /patient/timeline`.
- Query: `type` (comma list: `encounter, prescription, document, observation, followup, appointment, shared_notice`), `from`/`to` (YYYY-MM-DD, inclusive, UTC days), `source` (`own | shared | patient | <workspaceId>`), `doctor` (author user id), `q`, `limit` (1-100, default 30), `cursor`. Response `{items, nextCursor}`.
- Entry: `{type, id, refType, date, title, summary, author, source:{kind: clinic|patient, workspaceId, name}, version, versionCount, amended, historyPath, verificationBadge: clinician_authored|patient_submitted|reviewed, shared?:{sharedBy, via: grant|send, grantId, expiresAt, originClinic, label}, details}`. `id` is the underlying record id; `type + id` is unique (a consultation yields `encounter`, `prescription` and `observation` entries sharing its id).
- Architecture: each source is an adapter returning SQL branches over one fixed column list (`tlSelect`); the branches are `UNION ALL`ed, filtered, ordered by `(ts, type, id) desc` and keyset-paginated in one query (cursor = base64url of microsecond timestamp + type + id). Sources registered today: encounters (consultation, prescription, vitals), documents, appointments, shared notices, follow-ups (spec 09 plans and patient submissions, tables from migration 008). A new source = one `TimelineSource` pushed into `timelineSources` (or `registerTimelineSource`). Adapters see fixed params ($1 patient, $2 relationship, $3 workspace, $4/$5 ids shared via grants) and must only select what the viewer may read.
- Doctor scope: own signed encounters, vitals, appointments, follow-ups and documents of this relationship (including sent-by-patient documents while the send is not revoked), plus items matched by active grants to this workspace. Grants are resolved per request with spec 08 `candidates()`/`matches()`, so revoked or expired grants vanish immediately. Shared content needs an `active` relationship. Shared consultations expose the published version only (never history or private notes, in listing or search). Private notes are searched and shown only for the `doctor` role on the authoring workspace's own encounters.
- Patient scope: patient uploads, published consultations (published version only), published documents, vitals of published consultations, appointments and follow-ups of relationships that were accepted (`active`/`ended`), and notices of the patient's own grants. History and private notes are never selected by any patient-mode branch, so search cannot match them either.
- Audit/privacy: each doctor page view writes `timeline.viewed` (counts only) and a `shared_access_log` row per distinct shared consultation/document shown, so the patient sees it in their access log (F08-7).
- Decisions: draft encounters and `administrative` documents are not on the timeline; voided vitals excluded; one `observation` entry per encounter; amended entries show `versionCount` and, for the authoring clinic, `historyPath` (`/encounters/:id/versions`); shared and patient views show the version but no history link (no such endpoint for them).
- Performance: filters are pushed into each branch by the planner. With 5,000 documents + 3,000 appointments for one relationship a page query ran in about 50 ms (top-N sort over that relationship's rows); existing indexes (`encounters_patient_idx`, `documents_relationship_idx`, `documents_patient_idx`, `appointments_patient_idx`, `observations_encounter_idx`) cover the scoping predicates, so no migration was added. Text search is an `ilike` within the already-scoped rows (no trigram index); revisit if a single patient ever exceeds tens of thousands of entries.

**Dashboard:** patient detail page now has Overview / Timeline tabs (`TimelineSection.tsx`): type chips with icons, date range, source filter, debounced search, load-more, badges, "shared by patient from <clinic> until <date>" markers, links to the encounter or shared encounter/document pages.

**Patient app:** new History tab (`timeline_page.dart`, `timeline_detail.dart`, `timeline_models.dart`): search, type chips, date range, source dropdown (all, my uploads, per clinic), infinite scroll, pull to refresh, provenance and badge on every tile; tapping opens a visit view (`/patient/encounters/:id`), a document view (list from `/patient/documents`, pages through `/patient/documents/:id/pages/:n/link`), or a summary sheet for appointments, follow-ups and sharing notices.

**Not verified:** no device/simulator run of the Flutter app, no browser run of the dashboard (type-checked and built only).
