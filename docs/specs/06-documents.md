# 06 — Documents & Prescription Capture (P0)

**Source:** BR-01, BR-04, RULE-009. OCR/AI deferred.

## User stories
- As a doctor, I photograph a paper prescription or lab result and attach it to the encounter.
- As a patient, I upload old reports and images to my own history.
- As staff, I upload scans for the doctor's review.

## Functional requirements
| ID | Requirement |
|----|-------------|
| F06-1 | Camera-first capture with multi-page, crop, auto-rotate, and compression; file picker for PDF/JPEG/PNG. |
| F06-2 | Document categories: prescription, lab result, imaging, report, other. Date and optional title/notes. |
| F06-3 | Provenance: `uploader_id`, `uploader_role`, `source` (patient / clinician / staff). Patient uploads display as "patient-submitted, unverified". |
| F06-4 | A clinician may mark a patient upload as **reviewed** — this adds a verification entry, never changes the original or its source. |
| F06-5 | Private encrypted object storage; access only via short-lived signed URLs after an authorization check. |
| F06-6 | File validation: type allow-list, size limits (default 15 MB), malware scan before availability. |
| F06-7 | Quotas by plan (Doctor Free vs Pro) with clear usage display. |
| F06-8 | Deleting a clinician document = soft-delete with tombstone and audit; patient may delete their own uploads unless already shared/incorporated by a provider (retained copy rules apply). |

## Acceptance criteria
- A direct storage URL cannot be fetched without a valid signature; signed URLs expire (≤10 min).
- Receptionist uploads limited to administrative categories unless the doctor enables more.
- Every file view/download is audited.

## Audit events
upload, view, download, delete, reviewed-mark.

## Implementation notes
- **Pages:** one document has 1-20 image pages, or exactly one PDF. Types are judged by the file's own bytes (JPEG, PNG, WebP, PDF), never by the name or content-type the client sends; a renamed executable is refused with `415`. Limit 15 MB per file.
- **Scan before availability:** every file passes a `Scanner` before anything is stored; a failure returns `422 malware_detected` and stores nothing. The default scanner only recognises the EICAR test string and must be replaced (ClamAV or a cloud scanner) before real data.
- **Storage:** behind an `ObjectStore` interface (local disk implementation for now). Each file is encrypted with its own AES-256-GCM data key, wrapped by a master key (`DOCUMENT_ENCRYPTION_KEY`) held outside the object store, so rotating the master key only re-wraps small keys. Object keys are random ids with no names or patient data.
- **Access (F06-5):** the API authorizes first (`GET .../pages/:n/link`), then returns a signed path valid for 10 minutes. `GET /files/:token` re-checks, at the moment of use, that the document is not deleted, the staff member still has an active membership and the document is still visible to their clinic (or, for a patient, still theirs and either their own upload or published). So removing staff, revoking a share, unpublishing or deleting kills links that were already issued. Responses are `no-store`, `nosniff` and sandboxed.
- **Roles:** uploading needs `documents.upload`; anything other than the `administrative` category also needs `documents.upload_clinical` (doctor and nurse; not the front desk). Front desk lists and opens only clinic-uploaded administrative files; clinical documents return `404`, not `403`, so their existence is not revealed.
- **Provenance (RULE-009):** `source` is `clinician`, `staff` or `patient`, and the API labels patient uploads `patient_submitted_unverified`. A doctor's review is a separate `document_reviews` row; the original is never changed.
- **Patient uploads stay private** until the patient sends one to a clinic they are actively connected to (`POST /patient/documents/:id/send`). This is a minimal, revocable document-level share so that review (F06-4) works now; spec 08 generalises it. Revoking, or ending the relationship, hides the document from the clinic immediately, but the clinic's audit history of earlier views remains.
- **Deletion (F06-8):** clinic documents are tombstoned with a required reason (uploader or doctor only); the bytes are kept for retention but nothing serves them. A patient's own upload is truly erased, unless it was ever sent to a clinic, in which case deletion is refused (`already_shared`) because the clinic may lawfully hold a copy.
- **Publishing:** clinic documents reach the patient only after the doctor publishes them; administrative documents cannot be published.
- **Access log:** every file view is written to the append-only `document_access` table (usable as the patient-facing access log in spec 08) and, for clinic views, to the audit chain. Audit entries hold ids, category and page counts, never titles, notes or file names.
- **Quotas (F06-7):** a single placeholder limit (500 MB per clinic, 200 MB per patient) until plans exist. Tombstoned clinic documents still count because their bytes are kept.
- **Documents on encounters (F05-1):** a document can be attached to an encounter of the same patient at upload time and is listed on the encounter page.
