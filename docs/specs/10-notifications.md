# 10 — Notifications (P0)

**Source:** BR-07.

## Functional requirements
| ID | Requirement |
|----|-------------|
| F10-1 | Channels: push (primary), SMS fallback for appointment reminders (cost-gated), in-app inbox. |
| F10-2 | Triggers: appointment reminder/change, follow-up reminder, new shared document, access request, grant expiring, staff invitation. |
| F10-3 | **Privacy:** push/SMS text is generic (e.g. "You have a new update from your clinic"); no diagnosis, medication or result values. Details only after authenticated app open. |
| F10-4 | Per-user preferences: channel, quiet hours, per-type opt-out (security notices cannot be disabled). |
| F10-5 | Consent recorded before sending SMS/push to patients registered by a doctor. |
| F10-6 | Delivery log with retry and failure status; idempotent sends. |
| F10-7 | Templates in Arabic and English with RTL support. |

## Acceptance criteria
- Inspecting any push payload never reveals clinical content.
- A user who opted out of reminders receives none, but still receives mandatory security notices.
