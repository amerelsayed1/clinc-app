# 02 — Clinic Workspace & Staff (P0)

**Source:** BR-05, RULE-004, 005, 006, 010. Decision: one doctor = one workspace.

## User stories
- As a doctor, I create my workspace (optional display name) in minutes.
- As a doctor, I invite a receptionist and/or nurse, adjust what they can do, and revoke them instantly.
- As staff, every action I take is recorded under my own account.

## Functional requirements
| ID | Requirement |
|----|-------------|
| F02-1 | Creating a workspace makes the doctor its owner. Clinic name optional. |
| F02-2 | Doctor invites staff by phone/email with a role (receptionist or nurse); invitation expires and is single-use. |
| F02-3 | Roles are default permission bundles; the doctor can switch individual permissions off (granular custom roles = P1). |
| F02-4 | Doctor can suspend or remove staff; sessions are revoked immediately. |
| F02-5 | Staff sees a patient's clinical data only if the patient has an active relationship with this workspace **and** the role permits it (RULE-004). |
| F02-6 | Data model supports many doctors per workspace and many workspaces per user; MVP UI does not expose this. |

## Default permission matrix
| Capability | Doctor | Nurse | Receptionist |
|---|:-:|:-:|:-:|
| Register / search patients | ✔ | ✔ | ✔ |
| Edit demographics | ✔ | ✔ | ✔ |
| Manage appointments / check-in | ✔ | view | ✔ |
| Record vitals / observations | ✔ | ✔ | ✘ |
| Upload documents | ✔ | ✔ | ✔ (administrative types only) |
| View clinical notes / diagnoses | ✔ | limited (configurable) | ✘ |
| Create encounter, diagnosis, prescription | ✔ | ✘ | ✘ |
| Sign / amend clinical records | ✔ | ✘ | ✘ |
| Create follow-up plans | ✔ | ✘ | ✘ |
| Invite / remove staff, change permissions | ✔ | ✘ | ✘ |
| View audit log | ✔ | ✘ | ✘ |

## Acceptance criteria
- A receptionist API call to create a diagnosis or prescription returns 403 regardless of client.
- Removing a staff member blocks their next request and leaves their past actions attributed to them.
- A nurse never sees internal doctor-only notes.

## Audit events
workspace created, invite sent/accepted/expired, permission changed, staff suspended/removed.
