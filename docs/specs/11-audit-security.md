# 11 — Audit & Security (P0)

**Source:** BR-08, RULE-007, RULE-008. Legal review (Law 151/2020) is a **gate** before real patient data.

## Functional requirements
| ID | Requirement |
|----|-------------|
| F11-1 | Append-only, tamper-evident audit log (hash-chained entries): actor, role, workspace, action, target, scope, IP/device, timestamp, result. |
| F11-2 | Audited: all clinical record reads of sensitive scope, creates/amendments, sharing events, file downloads, permission changes, auth events, exports. |
| F11-3 | Doctors can view their workspace's log; patients can view access to their own data (spec 08); platform admins access via break-glass with justification, itself audited. |
| F11-4 | Encryption in transit (TLS 1.2+) and at rest; managed keys with rotation; secrets never in the repo. |
| F11-5 | Authorization policy layer: role × relationship × grant, deny by default, with automated tests for the permission matrix and cross-doctor isolation. |
| F11-6 | Backups with tested restore, defined RPO/RTO, and incident-response runbook. |
| F11-7 | Data subject operations: export, correction request, retention policy and legally mandated retention overrides. |
| F11-8 | Mobile hardening: secure token storage, optional biometric lock, screenshot/app-switcher masking for clinical screens, no PHI in logs or analytics. |
| F11-9 | Threat model completed for sharing links/QR before enabling external access (P1). |

## Acceptance criteria
- Tampering with an audit row is detectable by chain verification job.
- Security test suite proves RULE-003 (cross-doctor isolation) and RULE-005 (receptionist limits) on every endpoint.
- No real patient data enters any environment before the legal-review checkpoint is signed off.
