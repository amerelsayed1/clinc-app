# Connected Healthcare Platform

> **Working name:** CareLink (not finalized)  
> **Document:** Business Requirements & Product Overview  
> **Version:** 1.0 — Draft  
> **Initial market:** Egypt; designed for future MENA expansion  
> **Business model:** Mobile-first B2B2C SaaS

## Vision

Make patient care easier for small medical practices while giving patients a unified, portable medical history they can securely share with multiple doctors.

The product starts with **one doctor and their small clinic team**—usually a receptionist and optionally a nurse. It is not intended to become a complex hospital-management platform in its first release.

## Core Principles

1. **Doctor-first simplicity:** Fast patient lookup, consultation notes, prescription capture and follow-up.
2. **Patient-centered history:** One patient can establish relationships with multiple independent doctors.
3. **Selective sharing:** A doctor does not automatically see records authored by another doctor; sharing is appropriately authorized and auditable.
4. **Small-practice focus:** The doctor is the clinic owner by default and can invite support staff.
5. **Clinical provenance:** Every medical record identifies its creator, source and time. Patient uploads remain distinguishable from clinician-authored records.
6. **Privacy by design:** Sensitive medical information requires appropriate access controls, consent and legal review.

## Target Users

| Role | Primary responsibility |
| --- | --- |
| Doctor / Clinic Owner | Consultations, clinical documentation, prescriptions, follow-up, staff access |
| Patient | View personal history, upload documents, share selected records, track follow-ups |
| Receptionist | Register patients, book appointments, manage check-in and waiting list |
| Nurse | Record authorized observations/vital signs, upload documents, assist doctor |
| Platform Administrator | Subscription operations, support, security and compliance administration |

### Ownership Model — Confirmed Decision

**MVP: One doctor = one clinic workspace.** A doctor can create a workspace, optionally add a clinic name, invite a receptionist or nurse, and start serving patients. Staff have their own accounts and restricted permissions. A patient can belong to multiple doctors' care relationships without merging those doctors' clinic workspaces.

**Future:** A clinic can contain multiple doctors, and a user may work across multiple clinics. The data model should be extensible to this, but the initial UI and workflows should not require organization, branch or complex enterprise administration.

## Business Objectives

| ID | Objective |
| --- | --- |
| BO-001 | Digitize patient records and consultation histories |
| BO-002 | Let patients connect with multiple healthcare providers |
| BO-003 | Enable secure, selective medical-history sharing |
| BO-004 | Improve continuity of care and patient follow-up |
| BO-005 | Simplify collaboration between a doctor, receptionist and nurse |
| BO-006 | Minimize consultation administration time |
| BO-007 | Validate a sustainable doctor/clinic subscription business |
| BO-008 | Prepare for future expansion in MENA |

## Core Business Requirements

### BR-01 — Unified Patient Medical Record

- Each patient has one platform identity and may connect to multiple independent doctors.
- The patient timeline includes visits, prescriptions, investigations, attachments, observations and follow-up events.
- Each record preserves its author, clinic/source, date, version and verification status.
- Patients may upload historical prescriptions, laboratory results and medical images.
- Records authored by clinicians cannot be silently changed by other clinicians.
- The platform distinguishes patient-submitted values from clinician-verified information.

### BR-02 — Patient–Doctor Relationships

- A doctor can register or invite a patient.
- A patient can connect with multiple doctors simultaneously.
- Patient identity linking should avoid accidental duplicate or cross-person record merging.
- Each doctor has access to records from their own care relationship and only additionally authorized shared records.
- Ending a relationship restricts future access as applicable while preserving records that must lawfully be retained.

### BR-03 — Medical History Sharing

- Patients can share selected files, record categories or a defined date range.
- Sharing specifies the recipient, scope, duration and purpose where appropriate.
- Patients can review active permissions and revoke future access.
- Access is logged with the recipient, record scope and timestamp.
- Secure links or QR-based access for verified external doctors is an option, subject to identity verification and threat modeling.
- Private/internal clinical notes are not automatically shareable merely because a patient is linked to a doctor.
- Revocation does not imply deletion of records already lawfully incorporated into another provider's medical chart.

### BR-04 — Consultations and Medical Documents

- Doctors can create encounters and document complaints, observations, diagnoses and plans.
- Doctors can photograph or upload prescriptions, tests and medical images.
- Doctors can record follow-up dates and compare historical measurements.
- Signed clinical records require traceable amendments rather than silent overwrites.
- OCR and AI assistance are deferred; any future extraction or clinical summary requires human review.

### BR-05 — Doctor-Owned Clinic and Staff

| ID | Requirement | MVP Priority |
| --- | --- | --- |
| BR-05.01 | Doctor creates and owns a single clinic workspace | P0 |
| BR-05.02 | Doctor invites a receptionist | P0 |
| BR-05.03 | Doctor invites a nurse | P0 |
| BR-05.04 | Doctor manages permissions and revokes access | P0 |
| BR-05.05 | Receptionist handles registration and appointments | P0 |
| BR-05.06 | Nurse enters authorized vitals and uploads documents | P0 |
| BR-05.07 | Every staff action is linked to an individual account | P0 |
| BR-05.08 | Multiple doctors in the same clinic | Future |
| BR-05.09 | Multi-branch enterprise administration | Out of MVP |

Roles are default permission bundles, not blanket access. Staff visibility must also respect the patient's care relationship, assigned duties and privacy policies. Non-clinical staff cannot approve diagnoses or prescriptions. Clinical actions require professionally authorized users.

### BR-06 — Patient Follow-up

- Doctors create follow-up plans and requested measurements.
- Patients receive reminders according to notification preferences and applicable consent.
- Patients can submit observations or attachments requested by the doctor.
- Doctors review progress in the patient timeline.
- Patient measurements are not represented as independently verified clinical findings.

### BR-07 — Notifications

- Appointment and follow-up reminders.
- Notifications for new shared documents and access requests.
- Consent-aware delivery; no diagnosis or other sensitive details in exposed push-notification previews.

### BR-08 — Security and Compliance

- Secure authentication, especially for clinician accounts; appropriate MFA.
- Least-privilege, role- and relationship-aware authorization on the server.
- Encryption in transit and at rest; safe key management.
- Immutable or tamper-evident audit records for sensitive access and modifications.
- Signed, expiring file access and protected object storage.
- Backup and tested restoration, incident response, export, retention and correction procedures.
- Guardian/dependent relationships require careful identity and permission safeguards.
- Conduct Egyptian legal and data-protection review before processing real patient data, including requirements under Law 151/2020 and its executive regulations. Expansion markets require separate legal review.

## Business Rules

| ID | Rule |
| --- | --- |
| RULE-001 | A patient can have multiple concurrent doctor relationships |
| RULE-002 | Clinical records must preserve author and provenance |
| RULE-003 | A doctor cannot see another doctor's records solely because they treat the same patient |
| RULE-004 | Clinic membership alone is insufficient for unrestricted record access |
| RULE-005 | Receptionists cannot create or approve medical diagnoses or prescriptions |
| RULE-006 | Only authorized professionals can approve clinical actions within their scope |
| RULE-007 | Sharing revocation blocks future access where applicable, not legally mandated retention |
| RULE-008 | Sensitive access and record changes must be auditable |
| RULE-009 | Patient uploads and clinician-authored records have distinct provenance |
| RULE-010 | Future multi-clinic users may hold different roles in each workspace |

## Primary User Journeys

### Doctor and Small Clinic Team

1. Doctor registers, verifies credentials and creates their practice workspace.
2. Doctor optionally invites receptionist and nurse.
3. Receptionist adds or finds a patient and schedules an appointment.
4. Nurse records authorized observations, if applicable.
5. Doctor opens the patient timeline, records encounter notes, scans prescription and requests follow-up.
6. Patient sees the information explicitly published to them.

### Patient and Multiple Doctors

1. Patient creates or claims their identity and connects with Doctor A.
2. Doctor A creates encounter records and publishes shareable artifacts.
3. Patient later consults Doctor B at another practice.
4. Patient authorizes selected history and investigation results for Doctor B.
5. Doctor B accesses only approved material and records a separate encounter.
6. Patient can later review and adjust active sharing permissions.

## MVP Scope

**In scope (P0):** Doctor and patient accounts; one-doctor clinic workspace; basic receptionist and nurse roles; patient registration/search; encounter notes; prescription/photo upload; medical timeline; multiple doctor relationships; controlled record sharing; appointments and basic follow-up; audit trail; essential security and privacy workflows.

**Phase 2:** Specialty forms, advanced follow-up analytics, granular custom staff roles, improved secure external sharing, OCR, reviewed AI summaries, and patient family/dependent profiles after dedicated policy design.

**Later:** Multi-doctor clinics, multiple branches, video consultations, laboratory and insurance integrations, FHIR interoperability, sophisticated finance/inventory, and doctor marketplace.

## Business Model — Hypotheses to Validate

| Plan | Initial pricing hypothesis | Scope |
| --- | --- | --- |
| Doctor Free | EGP 0 | Limited usage for trial and adoption |
| Doctor Pro | EGP 499/month | Core patient/consultation workflow with larger limits |
| Small Clinic | From EGP 1,299/month | Doctor plus staff/team administration |
| Patient Core | Free | Essential record access and sharing |

These are **test prices**, not validated willingness-to-pay or profitability estimates. Assess storage, messaging, compliance, support, payment processing and customer acquisition costs before committing.

## Success Measures and Validation

- Interview 15–20 doctors from relevant specialties and at least 10 patients with repeated visits.
- Validate consultation-entry time, adoption barriers and willingness to pay.
- Pilot with 5–10 small practices after security and legal readiness.
- Track weekly active doctors, encounters documented, record-sharing usage, follow-up completion, 30/90-day retention, trial-to-paid conversion and safety incidents.
- Treat quantitative targets as hypotheses until baseline measurements exist.

## Risks

| Risk | Mitigation |
| --- | --- |
| Doctors continue using paper | Camera-first, low-friction consultation UX |
| Competing clinic systems offer similar capabilities | Differentiate on patient-centered continuity and controlled sharing |
| Unauthorized disclosure or non-compliance | Legal review, consent model, access controls, audit and testing |
| Patients resist app installation | Consider secure limited-access web views |
| Mixed provenance and duplicate patient identities | Explicit source labels and careful identity reconciliation |
| Storage and notification costs | Quotas, lifecycle rules, monitoring and unit economics |

## Open Decisions

1. **Sharing policy:** Per-request approval, time-scoped standing permissions, or hybrid by record sensitivity? Recommended: hybrid, with explicit consent and review.
2. **External doctor access:** Registered clinicians only at launch, or verified time-limited web access? Needs identity-verification design.
3. **Dependents:** Include guardian-managed child profiles at MVP or defer? Recommended: defer until consent and guardianship design is complete.
4. **Practice identity:** Optional clinic display name versus mandatory legal practice verification requirements.
5. **Patient identity:** Phone-based onboarding, verified identity methods and duplicate-record resolution.
6. **Subscriptions:** Final limits, trial period, taxes, billing and cancellation policy.

## Suggested Technology Direction (Not a BRD Commitment)

- Flutter mobile applications for doctor and patient experiences.
- ASP.NET Core backend; PostgreSQL database; private encrypted object storage.
- Modular monolith first, with clear modules for identity, practices, records, encounters, sharing, staff, follow-ups and billing.
- API/server-side access enforcement and a design extensible to healthcare data interoperability standards.

## Roadmap — Planning Assumptions

1. **Discovery and validation:** ~2 weeks.
2. **MVP implementation:** ~8–12 weeks for a focused, appropriately staffed team; subject to security/legal scope.
3. **Controlled pilot:** ~4–6 weeks after readiness review.
4. **Commercial launch:** Only after evidence of clinician adoption, privacy readiness and sustainable unit economics.

## Document Status

**Draft for founder review.** The confirmed ownership direction is **Doctor-First / Single-Doctor Practice MVP**. Regulatory conclusions, prices, pilot targets and open consent decisions remain subject to validation. This README is a business/product starting point; detailed PRD, user stories, permission matrix, domain/data models and acceptance criteria should be maintained separately as the project advances.

---

## Development

Stack: Node.js + TypeScript (Fastify) · PostgreSQL · Flutter. Monorepo: `apps/api`, `apps/clinic` (doctor/staff), `apps/patient` and `apps/admin` (Flutter mobile apps), `packages/shared`, `packages/clinic_core` (shared Dart package). See `docs/runbook.md` for operations. Feature specs live in [`docs/specs`](docs/specs/README.md).

```bash
cp .env.example .env            # optional; defaults work for local dev
docker compose up -d db         # or use any local Postgres matching DATABASE_URL
npm install
OTP_DEV_ECHO=true npm run dev:api   # applies migrations on start, API on :3000
(cd apps/clinic && flutter run --dart-define=API_BASE_URL=http://localhost:3000)   # clinic app; same for apps/patient, apps/admin
npm test                            # API tests against a throwaway clinic_test database
npm run typecheck
```

Uploaded documents are stored encrypted under `STORAGE_DIR` (default `.data/objects`). Set `DOCUMENT_ENCRYPTION_KEY` (32 random bytes, base64) in production; a fixed dev key is used otherwise. The storage layer and the malware scanner are interfaces (`apps/api/src/storage.ts`): swap in S3/GCS and a real scanner (e.g. ClamAV) before handling real patient data.

With `OTP_DEV_ECHO=true` (never in production) the sign-in code is shown on screen instead of being sent by SMS. To approve a doctor's licence, make a platform admin once with `npm run make-admin -w @clinic/api -- +20…` and call `POST /admin/doctors/:userId/decision`.
