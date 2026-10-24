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

## Implementation notes

**Status:** implemented as a vertical slice (migration `009_notifications.sql`, API, dashboard, patient app, admin app).

### API (`apps/api/src/notifications.ts`, `routes/notifications.ts`)
- **Tables:** `notifications` (inbox row = source of truth; `idempotency_key` unique; `status` pending/sent/failed/suppressed; `attempts`, `last_error`, `sent_at`, `read_at`, `deliver_after`), `notification_deliveries` (per-channel delivery log with retry state, F10-6), `notification_preferences`, `notification_consents` (append-only, newest row per channel wins), `device_tokens` (bound to the session; a token of a revoked session is never pushed to).
- **Channels:** `PushSender` (dev stand-ins `consolePush`, `memoryPush` outbox) and the existing `SmsSender`. `buildApp(pool, { push })` injects a real provider. In-app inbox is always on.
- **Routing rules:** push to every live device; SMS only as a cost-gated fallback for time-sensitive types (appointment reminder/change/cancel, phone-change, MFA-disabled) when there is no push path, or after push exhausted its retries. A phone-change notice also texts the previous number.
- **Privacy (F10-3):** push/SMS text comes from `TEMPLATES[type].external` (ar + en), takes no parameters and is static. The push payload data is only an opaque `nid`. Inbox text uses a whitelist of non-clinical params (`ALLOWED_PARAMS`: clinic name, role, ids, appointment time); `validateParams` throws on anything else, including the `FORBIDDEN_PARAMS` list. The inbox says e.g. "New document available from Clinic X" with no title/category/diagnosis. The unit tests render every template in both languages and scan for placeholders, clinical words and canary values.
- **Preferences (F10-4):** locale (`ar` default, `localeExplicit` tells clients whether the user ever chose), channels, quiet hours (HH:MM + IANA time zone, midnight wrap), per-type opt-outs. Security types are `mandatory`: `PUT` with one in `disabledTypes` returns 400 `mandatory_notice`; they bypass opt-outs, channel preferences and quiet hours. Opted-out types are stored as `suppressed` (kept for the delivery log, hidden from the inbox). Quiet hours hold push/SMS until the window ends (`deliver_after`); the inbox item is visible immediately.
- **Consent (F10-5):** any user with a `patients` row needs a recorded `push`/`sms` consent before the matching channel is used (`GET/PUT /notification-consent`); until then only the inbox. Staff are not gated. Patients not yet claimed have no account, so are not notified at all (the invitation SMS from spec 03 is unchanged).
- **Delivery (F10-6):** `Notifier.notify` is idempotent per key; failed sends retry with exponential backoff (30 s, 2 min, 8 min; 4 attempts) and end `failed` with `last_error`. Rows are leased with `for update skip locked`, so concurrent workers never double-send.
- **Triggers wired:** appointment reminder (24 h lead, one per appointment time, `dispatchDueReminders(pool, now, notifier)`), reschedule, cancel; document published; encounter published (per version); staff invitation (SMS kept, plus inbox for existing accounts) and invitation accepted (to the inviter); spec 08 access request received (patient), approved/denied (requester), new grant to the clinic owner, grant expiring (both sides, once); security: phone changed, MFA enabled/disabled, sign-in from an unseen device name (not the first ever sign-in); spec 09 follow-up reminders via `dueReminders` (carries only the plan id; the measurement name never leaves the system).
- **Jobs:** `app.runNotificationJobs()` (also `notifier.runJobs(now)`) runs reminders, expiring grants, registered sources and the due/retry queue; `server.ts` ticks it every 60 s. Other features can add reminders with `app.notifier.registerReminderSource(name, async (pool, now) => [{ userId, type, key, params }])`; the follow-up source is registered in `app.ts`.
- **Endpoints:** `GET /notifications` (cursor, `unreadOnly`), `GET /notifications/unread-count`, `POST /notifications/:id/read`, `POST /notifications/read-all`, `GET/PUT /notification-preferences`, `GET/PUT /notification-consent`, `POST /devices`, `DELETE /devices/:id`, `DELETE /devices?token=`.

### Clients
- **Dashboard:** bell with unread badge in the header, `/notifications` inbox (cursor paging, mark read/all, links for sharing/security/team items, RTL when the language is Arabic) and `/notifications/preferences` (language, channels, quiet hours, per-type toggles, locked security rows). English UI; only the notification text itself is localized server-side.
- **clinic_core** (`src/notifications`): `NotificationsKit` (repository, `LocaleController`, `UnreadController`, `PushRegistration`), `NotificationInboxView`, `NotificationPreferencesScreen`, `NotificationConsentPrompt`, `CareStrings` (ar/en, delegates with Material/Widgets/Cupertino so Arabic is RTL). Patient and admin apps use the same screens; both MaterialApps take the locale from `kit.locale`, which is switchable in Notification settings and adopted from the server on sign-in. Only the new screens are localized; older screens remain English.
- **Patient app:** Inbox tab with unread badge, Account > Notifications, consent prompt on first launch (an explicit "No thanks" is also recorded and never re-asked). **Admin app:** Inbox tab and the same settings screen.
- **Push provider seam:** `PushRegistrar` (`requestToken`, `onTokenRefresh`, `deleteToken`) with a `NoopPushRegistrar` default; no Firebase dependency. To enable FCM/APNs implement the interface in the app (sample in the dartdoc of `push.dart`), pass it to `NotificationsKit(api, registrar: ...)` in `main.dart`, add the platform Firebase setup, and replace `consolePush` on the server with an FCM/APNs `PushSender`. The OS permission is never requested before the user consents.

### Deviations and limits
- No real push gateway or device was exercised: server push goes to the in-memory/console sender, and the Flutter apps were verified with widget tests only (no simulator or device run).
- Web push for the dashboard is not implemented (the bell polls the unread count every 30 s).
- Reminder lead time (24 h) and retry constants are code constants (`REMINDER_LEAD_HOURS`, `RETRY`), not settings. The SMS fallback is cost-gated by rule (no push path, consent, type allows SMS), not by a monetary budget.
- The "no push/SMS before consent" rule applies to every account that has a patient record, not only those whose record a doctor created.
