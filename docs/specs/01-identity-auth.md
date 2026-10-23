# 01 — Identity & Authentication (P0)

**Source:** BR-08, Open Decision 5.

## User stories
- As a doctor, I register and verify my credentials so I can create a workspace.
- As a patient, I sign up with my phone number and claim any record a doctor already created for me.
- As staff, I accept an invitation and get my own account.
- As any user, I can sign in securely, recover access, and see/revoke active sessions.

## Functional requirements
| ID | Requirement |
|----|-------------|
| F01-1 | Account types: doctor, patient, receptionist, nurse, platform admin. One user may later hold several roles/workspaces (RULE-010). |
| F01-2 | Phone-number sign-up with OTP verification (primary for patients); email optional. |
| F01-3 | Doctor accounts require MFA (OTP or authenticator) and a credential-verification step (medical license number + document) before clinical actions are enabled. |
| F01-4 | Staff sign up only via a doctor's expiring, single-use invitation link/code. |
| F01-5 | Short-lived access tokens, rotating refresh tokens, per-device session list with remote revoke. |
| F01-6 | Rate limiting and lockout on OTP and login attempts. |
| F01-7 | Patient claim flow: when a doctor registers a patient by phone, the patient's later sign-up with the same verified phone links to that existing identity after OTP + confirmation (no automatic merge by name). |
| F01-8 | Account recovery with re-verification; changing phone requires OTP on old and new numbers. |

## Acceptance criteria
- Unverified doctors can create a workspace but cannot create encounters or prescriptions.
- OTP expires (≤5 min), is single-use, and is limited to 5 attempts.
- Revoking a session invalidates its refresh token within one request cycle.
- Claiming a record never merges two existing patient identities silently; conflicts go to manual resolution (see spec 03).

## Audit events
login, failed login, MFA enrolment, session revoke, credential verification decision, identity claim.

## Open questions
National-ID verification for patients; doctor license verification source (syndicate registry vs manual review).
