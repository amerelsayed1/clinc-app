# Operations runbook (spec 11)

Status: **draft for validation**. Every number marked `[VALIDATE]` is a placeholder target that must be confirmed with a real drill
and signed off before real patient data enters any environment. The legal-review gate (below) is **open**.

## 1. Environments and secrets

| Setting | Required in production | Notes |
|---|---|---|
| `NODE_ENV=production` | yes | Turns on the boot checks below, HSTS and disables CORS. |
| `JWT_SECRET` | yes | >= 32 random characters, unique per environment. |
| `DOCUMENT_ENCRYPTION_KEY` | yes | Base64 of exactly 32 random bytes (current master key). Never the development key. |
| `DOCUMENT_KEY_ID` | no (default `v1`) | Id stamped on everything wrapped with the current key. |
| `DOCUMENT_ENCRYPTION_KEYS_OLD` | during rotation | `id:base64,id:base64` of retired keys, decrypt only. |
| `DATABASE_URL` | yes | Not the `clinic:clinic@` development credentials. |
| `TRUST_PROXY` | behind a proxy | Hop count (`1`) or proxy addresses/CIDRs. Default: do not trust `X-Forwarded-For` (otherwise clients can forge audit IPs and dodge the per-IP rate limit). |
| `AUTH_RATE_LIMIT_PER_MIN` | no (60) | Per IP, all `/auth/*` calls. In-memory: use a shared store behind the `RateLimiter` interface when running more than one instance. |
| `EXPORT_RATE_LIMIT_PER_HOUR` | no (3) | Patient data exports per user. |
| `OTP_DEV_ECHO` | **must be unset** | The API refuses to boot in production when it is `true`. |

`assertProductionConfig` (apps/api/src/config.ts) refuses to start a production process with: a missing/short/default `JWT_SECRET`,
a missing/default/wrong-length `DOCUMENT_ENCRYPTION_KEY`, development database credentials, or `OTP_DEV_ECHO=true`.
Secrets live in the platform secret manager, never in the repository or in images.

### Transport and at-rest encryption (infrastructure, not in code)
- TLS 1.2+ terminates at the load balancer; the API sets HSTS in production. Verify with an external scan before go-live. `[VALIDATE]`
- Database and object-store volumes use provider-managed encryption at rest. Document files are additionally encrypted per file
  (AES-256-GCM, per-file data key wrapped by the master key). A managed KMS/HSM for the master key is **not implemented**; today the
  master key is an environment secret.

## 2. Backups and restore

Targets (placeholders): **RPO 15 minutes, RTO 4 hours** `[VALIDATE]`.

| What | How | Retention |
|---|---|---|
| PostgreSQL | Continuous WAL archiving + daily base backup (managed provider PITR) | 35 days `[VALIDATE]` |
| Object store (documents) | Versioned bucket + cross-region replication; objects are already encrypted | match DB |
| Secrets / keys | Master keys escrowed in the secret manager with a second custodian. **Losing the master key makes every stored document unrecoverable.** | indefinite |

Restore drill (run quarterly and before go-live; record date, duration and result here):
1. Restore the latest base backup + WAL to a scratch database at a chosen time; start the API against it with `NODE_ENV=production` secrets from the vault.
2. `GET /admin/audit/verify` (admin app > Audit): all chains must be intact. A restore that fails verification means the backup is suspect.
3. Open a document through a signed link (decrypts with the wrapped key) and sign in as a test doctor.
4. Measure the elapsed time against RTO and the data gap against RPO.

| Drill date | Duration | RPO achieved | Verified by | Notes |
|---|---|---|---|---|
| _not yet run_ | | | | Infrastructure drill outstanding |

## 3. Audit log integrity

- Every workspace has its own hash chain, plus one `global` chain for events without a clinic. Rows are append-only (database trigger) and each hash covers the previous one.
- The API verifies **all chains hourly** (server.ts) and logs `AUDIT CHAIN BROKEN` at error level: alert on that line. Admins can run it on demand (admin app > Audit, `GET /admin/audit/verify`); runs are kept in `audit_verifications`.
- Platform staff read a clinic's log only through break-glass (`POST /admin/break-glass`, justification >= 15 characters, <= 60 minutes, admin MFA required). The grant, each read and any refusal are written to **that clinic's** chain, where its owner sees them.
- Retention of the audit log: 10 years (policy value, pending legal review).

## 4. Incident response

Severity: **SEV1** confirmed or suspected exposure of patient data, audit-chain break, key compromise. **SEV2** outage of sign-in or documents. **SEV3** degraded.

1. **Declare** (anyone): page the on-call engineer and the security lead. Open an incident record with a timeline. Start the clock: legal notification duties may run from *awareness* `[VALIDATE with counsel]`.
2. **Contain**: revoke sessions (`update sessions set revoked_at = now()`), suspend affected staff memberships, rotate `JWT_SECRET` (signs everyone out) and, if key compromise is suspected, the master key (section 5). Block abusive IPs at the edge.
3. **Preserve**: snapshot the database and object store; export the affected clinic's audit log (`GET /workspace/audit/export` or break-glass) and run chain verification *before* changing anything.
4. **Investigate**: use audit filters (action, actor, record id, date range). `access.denied` rows show probing; `breakglass.*` shows platform access; `patient.exported` shows data-subject exports; `auth.refresh_reuse_detected` signals token theft.
5. **Notify**: affected clinics (owners can be contacted through the admin app), patients, and the regulator as required by Law 151/2020 `[VALIDATE with counsel]`. Never include PHI in SMS/push text.
6. **Recover and review**: fix, restore if needed (section 2), write a post-incident review within 5 working days, add a test that would have caught it.

Contacts (fill in before go-live): on-call, security lead, DPO / legal counsel, hosting provider support.

## 5. Master-key rotation (`DOCUMENT_ENCRYPTION_KEY`)

Document bytes are encrypted with per-file data keys; only the small wrapped keys (and TOTP secrets) depend on the master key, so rotation never rewrites files. Wrapped keys carry the id of the key that sealed them (`<id>.<base64>`; rows from before key ids are treated as id `v1`).

1. Generate a new key: `openssl rand -base64 32`.
2. Deploy with `DOCUMENT_KEY_ID=v2`, `DOCUMENT_ENCRYPTION_KEY=<new>` and `DOCUMENT_ENCRYPTION_KEYS_OLD=v1:<old key>`. New uploads and new TOTP enrolments use `v2`; old data still opens with `v1`.
3. Re-wrap existing data with the same environment: `npm run rotate-keys -w @clinic/api` (idempotent, safe to re-run). It rewrites `document_pages.wrapped_key` and `users.totp_secret_enc / totp_pending_enc`.
4. Verify nothing still references the old id: `select count(*) from document_pages where wrapped_key not like 'v2.%'` and the same for the two user columns must be 0.
5. Remove `DOCUMENT_ENCRYPTION_KEYS_OLD` from the environment, keep the old key offline in escrow for the backup retention window (old backups need it).
6. Record the rotation (date, who, reason). Rotate at least yearly and immediately on suspected exposure.

`JWT_SECRET` rotation signs every user out (access tokens and signed file links); do it in a quiet window.

## 6. Legal-review gate (OPEN)

Law 151/2020 review is a gate: **no real patient data in any environment until all items are signed off.**

| Item | Owner | Status |
|---|---|---|
| Lawful basis, consent wording and data-subject rights (export, correction) match the law | Counsel | open |
| Retention periods (`config.retention`, 10 years placeholders) and legal-hold procedure | Counsel | open |
| Cross-border transfer / hosting location | Counsel + infra | open |
| Breach-notification duties and timeline (section 4) | Counsel | open |
| Processor agreements (hosting, SMS gateway, push) | Counsel | open |
| Backup restore drill completed and recorded (section 2) | Infra | open |
| Penetration test of API and apps; fix criticals | Security | open |
| Threat model for sharing links / QR before enabling external access (F11-9, P1) | Security | open |

Sign-off: ______________________ date: __________ (reviewer, role)

Until this table is complete, environments must run on synthetic data only. The malware scanner (`eicarScanner`), SMS provider and push provider are development stand-ins and must be replaced first.
