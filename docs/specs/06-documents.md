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
