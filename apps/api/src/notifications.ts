import type { FastifyBaseLogger } from 'fastify';
import type pg from 'pg';
import { config } from './config.js';
import { consoleSms, type SmsSender } from './auth.js';
import { badRequest } from './errors.js';

// ---------------------------------------------------------------------------------------------
// Channel boundaries. Dev stand-ins mirror SmsSender in auth.ts: replace with FCM/APNs in production.
// ---------------------------------------------------------------------------------------------
export interface PushMessage {
  token: string;
  platform: string;
  title: string;
  body: string;
  /** Opaque routing data only (the notification id). Never clinical content. */
  data: { nid: string };
}
export interface PushSender {
  send(msg: PushMessage): Promise<void>;
}
export const consolePush: PushSender = {
  async send(m) {
    if (!config.isProd) console.log(`[push] -> ${m.platform}:${m.token.slice(0, 12)}: ${m.title} / ${m.body}`);
  },
};
/** In-memory outbox for tests and local debugging. */
export function memoryPush(): PushSender & { outbox: PushMessage[]; failNext: number } {
  const s = {
    outbox: [] as PushMessage[],
    failNext: 0,
    async send(m: PushMessage) {
      if (s.failNext > 0) {
        s.failNext--;
        throw new Error('push provider unavailable');
      }
      s.outbox.push(m);
    },
  };
  return s;
}

// ---------------------------------------------------------------------------------------------
// Templates (F10-3, F10-7). `external` text is what leaves the system in push/SMS: it takes NO
// parameters at all. `inbox` text is shown only inside the authenticated app and may use the
// whitelisted non-clinical params below.
// ---------------------------------------------------------------------------------------------
export const LOCALES = ['ar', 'en'] as const;
export type Locale = (typeof LOCALES)[number];

export const ALLOWED_PARAMS = ['clinicName', 'role', 'appointmentId', 'appointmentAt', 'documentId', 'encounterId', 'grantId', 'requestId', 'planId', 'invitationId'] as const;
export type ParamKey = (typeof ALLOWED_PARAMS)[number];
/** Names that must never appear as notification params (checked by tests and at runtime). */
export const FORBIDDEN_PARAMS = ['diagnosis', 'medication', 'prescription', 'prescriptions', 'value', 'values', 'result', 'results', 'measurementName', 'title', 'chiefComplaint', 'notes', 'privateNotes', 'reason', 'plan', 'history', 'vitals', 'patientName'];

type Text = { title: string; body: string };
type Localized = Record<Locale, Text>;
export interface Template {
  mandatory?: boolean; // security notices: ignore opt-outs and quiet hours
  smsFallback?: boolean; // F10-1: SMS only when there is no push path (cost-gated)
  params: readonly ParamKey[];
  external: Localized;
  inbox: Localized;
}

const GENERIC: Localized = {
  en: { title: 'Clinic', body: 'You have a new update from your clinic. Open the app to view it.' },
  ar: { title: 'العيادة', body: 'لديك تحديث جديد من عيادتك. افتح التطبيق للاطلاع عليه.' },
};
const REMINDER: Localized = {
  en: { title: 'Clinic', body: 'You have an upcoming appointment. Open the app for details.' },
  ar: { title: 'العيادة', body: 'لديك موعد قادم. افتح التطبيق للتفاصيل.' },
};
const SECURITY: Localized = {
  en: { title: 'Account security', body: 'There was a security update on your account. Open the app to review it.' },
  ar: { title: 'أمان الحساب', body: 'حدث تغيير أمني على حسابك. افتح التطبيق لمراجعته.' },
};
const ACTIVITY: Localized = {
  en: { title: 'Clinic', body: 'You have a new notification. Open the app to view it.' },
  ar: { title: 'العيادة', body: 'لديك إشعار جديد. افتح التطبيق للاطلاع عليه.' },
};

export const TEMPLATES = {
  appointment_reminder: {
    smsFallback: true,
    params: ['clinicName', 'appointmentId', 'appointmentAt'],
    external: REMINDER,
    inbox: {
      en: { title: 'Appointment reminder', body: 'You have an upcoming appointment at {clinicName}.' },
      ar: { title: 'تذكير بالموعد', body: 'لديك موعد قادم في {clinicName}.' },
    },
  },
  appointment_rescheduled: {
    smsFallback: true,
    params: ['clinicName', 'appointmentId', 'appointmentAt'],
    external: GENERIC,
    inbox: {
      en: { title: 'Appointment changed', body: 'Your appointment at {clinicName} was rescheduled.' },
      ar: { title: 'تم تغيير الموعد', body: 'تمت إعادة جدولة موعدك في {clinicName}.' },
    },
  },
  appointment_cancelled: {
    smsFallback: true,
    params: ['clinicName', 'appointmentId', 'appointmentAt'],
    external: GENERIC,
    inbox: {
      en: { title: 'Appointment cancelled', body: 'Your appointment at {clinicName} was cancelled.' },
      ar: { title: 'تم إلغاء الموعد', body: 'تم إلغاء موعدك في {clinicName}.' },
    },
  },
  document_published: {
    params: ['clinicName', 'documentId'],
    external: GENERIC,
    inbox: {
      en: { title: 'New document', body: 'New document available from {clinicName}.' },
      ar: { title: 'مستند جديد', body: 'يوجد مستند جديد من {clinicName}.' },
    },
  },
  encounter_published: {
    params: ['clinicName', 'encounterId'],
    external: GENERIC,
    inbox: {
      en: { title: 'New visit summary', body: 'A new visit summary is available from {clinicName}.' },
      ar: { title: 'ملخص زيارة جديد', body: 'يوجد ملخص زيارة جديد من {clinicName}.' },
    },
  },
  followup_reminder: {
    params: ['planId'],
    external: GENERIC,
    inbox: {
      en: { title: 'Follow-up reminder', body: 'You have a follow-up task due. Open it to continue.' },
      ar: { title: 'تذكير بالمتابعة', body: 'لديك مهمة متابعة مستحقة. افتحها للمتابعة.' },
    },
  },
  staff_invited: {
    params: ['clinicName', 'role', 'invitationId'],
    external: ACTIVITY,
    inbox: {
      en: { title: 'Workspace invitation', body: 'You were invited to join {clinicName} as {role}.' },
      ar: { title: 'دعوة للانضمام', body: 'تمت دعوتك للانضمام إلى {clinicName} بصفة {role}.' },
    },
  },
  staff_joined: {
    params: ['role', 'invitationId'],
    external: ACTIVITY,
    inbox: {
      en: { title: 'Invitation accepted', body: 'A new {role} joined your clinic.' },
      ar: { title: 'تم قبول الدعوة', body: 'انضم عضو جديد ({role}) إلى عيادتك.' },
    },
  },
  access_request_received: {
    params: ['clinicName', 'requestId'],
    external: GENERIC,
    inbox: {
      en: { title: 'Access request', body: '{clinicName} asked to view some of your records. Review the request.' },
      ar: { title: 'طلب اطلاع', body: 'طلبت {clinicName} الاطلاع على بعض سجلاتك. راجع الطلب.' },
    },
  },
  access_request_approved: {
    params: ['requestId', 'grantId'],
    external: ACTIVITY,
    inbox: {
      en: { title: 'Access request approved', body: 'A patient approved your access request.' },
      ar: { title: 'تمت الموافقة على الطلب', body: 'وافق المريض على طلب الاطلاع.' },
    },
  },
  access_request_denied: {
    params: ['requestId'],
    external: ACTIVITY,
    inbox: {
      en: { title: 'Access request declined', body: 'A patient declined your access request.' },
      ar: { title: 'تم رفض الطلب', body: 'رفض المريض طلب الاطلاع.' },
    },
  },
  grant_received: {
    params: ['grantId'],
    external: ACTIVITY,
    inbox: {
      en: { title: 'New shared records', body: 'A patient shared records with your clinic.' },
      ar: { title: 'سجلات جديدة مشاركة', body: 'شارك مريض سجلاته مع عيادتك.' },
    },
  },
  grant_expiring: {
    params: ['grantId'],
    external: ACTIVITY,
    inbox: {
      en: { title: 'Shared access ending soon', body: 'A record-sharing grant is about to expire.' },
      ar: { title: 'انتهاء المشاركة قريباً', body: 'ستنتهي صلاحية مشاركة السجلات قريباً.' },
    },
  },
  security_phone_changed: {
    mandatory: true,
    smsFallback: true,
    params: [],
    external: SECURITY,
    inbox: {
      en: { title: 'Phone number changed', body: 'The phone number on your account was changed. If this was not you, contact support.' },
      ar: { title: 'تم تغيير رقم الهاتف', body: 'تم تغيير رقم الهاتف على حسابك. إذا لم تكن أنت، تواصل مع الدعم.' },
    },
  },
  security_mfa_enabled: {
    mandatory: true,
    params: [],
    external: SECURITY,
    inbox: {
      en: { title: 'Two-step verification enabled', body: 'Two-step verification was turned on for your account.' },
      ar: { title: 'تم تفعيل التحقق بخطوتين', body: 'تم تفعيل التحقق بخطوتين لحسابك.' },
    },
  },
  security_mfa_disabled: {
    mandatory: true,
    smsFallback: true,
    params: [],
    external: SECURITY,
    inbox: {
      en: { title: 'Two-step verification disabled', body: 'Two-step verification was turned off for your account. If this was not you, secure your account.' },
      ar: { title: 'تم إيقاف التحقق بخطوتين', body: 'تم إيقاف التحقق بخطوتين لحسابك. إذا لم تكن أنت، قم بتأمين حسابك.' },
    },
  },
  security_new_login: {
    mandatory: true,
    params: [],
    external: SECURITY,
    inbox: {
      en: { title: 'New device sign-in', body: 'Your account was signed in on a new device. If this was not you, revoke the session.' },
      ar: { title: 'تسجيل دخول من جهاز جديد', body: 'تم تسجيل الدخول إلى حسابك من جهاز جديد. إذا لم تكن أنت، أنهِ الجلسة.' },
    },
  },
} as const satisfies Record<string, Template>;

export type NotificationType = keyof typeof TEMPLATES;
export const NOTIFICATION_TYPES = Object.keys(TEMPLATES) as NotificationType[];
export const MANDATORY_TYPES = NOTIFICATION_TYPES.filter((t) => (TEMPLATES[t] as Template).mandatory);
const tpl = (t: string): Template => {
  const x = (TEMPLATES as Record<string, Template>)[t];
  if (!x) throw new Error(`Unknown notification type ${t}`);
  return x;
};

const FALLBACK_NAMES: Record<Locale, Record<string, string>> = {
  en: { clinicName: 'your clinic', role: 'staff member' },
  ar: { clinicName: 'عيادتك', role: 'موظف' },
};
const ROLE_NAMES: Record<Locale, Record<string, string>> = {
  en: { nurse: 'nurse', receptionist: 'receptionist', doctor: 'doctor' },
  ar: { nurse: 'ممرض/ة', receptionist: 'موظف استقبال', doctor: 'طبيب' },
};

function fill(text: string, locale: Locale, params: Record<string, unknown>): string {
  return text.replace(/\{(\w+)\}/g, (_m, k: string) => {
    let v = params[k];
    if (k === 'role' && typeof v === 'string') v = ROLE_NAMES[locale][v] ?? v;
    return typeof v === 'string' && v ? v : (FALLBACK_NAMES[locale][k] ?? '');
  });
}
/** The text inside the authenticated inbox. Non-clinical, localized. */
export function renderInbox(type: string, locale: Locale, params: Record<string, unknown>): Text {
  const t = tpl(type).inbox[locale];
  return { title: fill(t.title, locale, params), body: fill(t.body, locale, params) };
}
/** The text that leaves the system in push/SMS. Takes no params by construction. */
export function renderExternal(type: string, locale: Locale): Text {
  return tpl(type).external[locale];
}

export function validateParams(type: string, params: Record<string, unknown>) {
  const allowed = new Set<string>(tpl(type).params);
  for (const k of Object.keys(params)) {
    if (!allowed.has(k) || FORBIDDEN_PARAMS.includes(k)) throw new Error(`Parameter "${k}" is not allowed for notification ${type}`);
  }
}

// ---------------------------------------------------------------------------------------------
// Preferences, quiet hours, consent
// ---------------------------------------------------------------------------------------------
export interface Prefs {
  locale: Locale;
  channels: string[];
  quietStart: string | null;
  quietEnd: string | null;
  timezone: string;
  disabledTypes: string[];
}
export const DEFAULT_PREFS: Prefs = { locale: 'ar', channels: ['push', 'sms'], quietStart: null, quietEnd: null, timezone: 'Africa/Cairo', disabledTypes: [] };

type Db = Pick<pg.Pool, 'query'>;

export async function loadPrefs(db: Db, userId: string): Promise<Prefs> {
  const r = (await db.query('select * from notification_preferences where user_id = $1', [userId])).rows[0];
  if (!r) return { ...DEFAULT_PREFS };
  return { locale: r.locale, channels: r.channels, quietStart: r.quiet_start, quietEnd: r.quiet_end, timezone: r.timezone, disabledTypes: r.disabled_types };
}

const toMin = (hhmm: string) => Number(hhmm.slice(0, 2)) * 60 + Number(hhmm.slice(3, 5));

/** If `now` falls in the user's quiet window, returns the instant it ends; otherwise null. */
export function quietUntil(prefs: Pick<Prefs, 'quietStart' | 'quietEnd' | 'timezone'>, now: Date): Date | null {
  if (!prefs.quietStart || !prefs.quietEnd || prefs.quietStart === prefs.quietEnd) return null;
  let parts: Record<string, string>;
  try {
    parts = Object.fromEntries(new Intl.DateTimeFormat('en-GB', { timeZone: prefs.timezone, hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' }).formatToParts(now).map((p) => [p.type, p.value]));
  } catch {
    return null; // unknown time zone: fail open rather than hold messages forever
  }
  const cur = Number(parts.hour) * 60 + Number(parts.minute);
  const s = toMin(prefs.quietStart);
  const e = toMin(prefs.quietEnd);
  const inside = s < e ? cur >= s && cur < e : cur >= s || cur < e;
  if (!inside) return null;
  const minutesLeft = (e - cur + 1440) % 1440;
  return new Date(now.getTime() + minutesLeft * 60_000 - Number(parts.second) * 1000);
}

export interface Consent {
  push: boolean | null;
  sms: boolean | null;
}
export async function loadConsent(db: Db, userId: string): Promise<Consent> {
  const rows = (await db.query(`select distinct on (channel) channel, granted from notification_consents where user_id = $1 order by channel, id desc`, [userId])).rows;
  const out: Consent = { push: null, sms: null };
  for (const r of rows) out[r.channel as 'push' | 'sms'] = r.granted;
  return out;
}
/** F10-5: users who exist as a patient record (registered by a doctor) need explicit consent for push/SMS. */
export async function consentRequired(db: Db, userId: string): Promise<boolean> {
  return (await db.query('select 1 from patients where user_id = $1', [userId])).rowCount! > 0;
}

// ---------------------------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------------------------
export interface NotifyInput {
  userId: string;
  type: NotificationType;
  params?: Partial<Record<ParamKey, string>>;
  /** Same key twice = one notification (F10-6). */
  key: string;
  /** Do not deliver before this instant. */
  notBefore?: Date;
  /** Send SMS here instead of the account phone (e.g. the previous number after a phone change). */
  smsTo?: string;
}

export const RETRY = { maxAttempts: 4, baseSeconds: 30, factor: 4, leaseSeconds: 300 };
export const backoffSeconds = (attemptsSoFar: number) => RETRY.baseSeconds * RETRY.factor ** (attemptsSoFar - 1);

export interface ReminderItem {
  userId: string;
  type: NotificationType;
  key: string;
  params?: Partial<Record<ParamKey, string>>;
}
export type ReminderSource = (pool: pg.Pool, now: Date) => Promise<ReminderItem[]>;

export class Notifier {
  private sources = new Map<string, ReminderSource>();
  constructor(
    private pool: pg.Pool,
    private sms: SmsSender = consoleSms,
    private push: PushSender = consolePush,
    private log?: Pick<FastifyBaseLogger, 'error'>,
  ) {}

  /**
   * Extension point for other features (e.g. follow-up plans): register a function that returns the
   * reminders due at `now`. Each item is delivered idempotently by its `key`, so a source may return
   * the same item on every run. Called by runJobs().
   */
  registerReminderSource(name: string, source: ReminderSource) {
    this.sources.set(name, source);
  }

  /** Creates the inbox item (once per key) and attempts delivery right away. Never throws for delivery problems. */
  async notify(input: NotifyInput, now = new Date()): Promise<string | null> {
    try {
      return await this.create(input, now);
    } catch (e) {
      if (e instanceof Error && e.message.includes('is not allowed for notification')) throw e; // programming error: fail loudly
      this.log?.error(e);
      return null;
    }
  }

  private async create(input: NotifyInput, now: Date): Promise<string | null> {
    const params = input.params ?? {};
    validateParams(input.type, params);
    const t = tpl(input.type);
    const prefs = await loadPrefs(this.pool, input.userId);
    const optedOut = !t.mandatory && prefs.disabledTypes.includes(input.type);
    const r = await this.pool.query(
      `insert into notifications (user_id, type, template_key, params, idempotency_key, status, deliver_after, sms_to, sent_at)
       values ($1,$2,$2,$3,$4,$5,$6,$7,null) on conflict (idempotency_key) do nothing returning id`,
      [input.userId, input.type, JSON.stringify(params), input.key, optedOut ? 'suppressed' : 'pending', input.notBefore ?? now, input.smsTo ?? null],
    );
    const id = r.rows[0]?.id as string | undefined;
    if (!id) return null; // duplicate send
    if (!optedOut) await this.process(now, id);
    return id;
  }

  /** Plans channels for notifications that are due, then sends/retries due deliveries. */
  async process(now = new Date(), onlyId?: string): Promise<{ planned: number; attempted: number }> {
    const due = (
      await this.pool.query(
        `select n.*, u.phone from notifications n join users u on u.id = n.user_id
          where n.status = 'pending' and n.planned_at is null and n.deliver_after <= $1 and ($2::uuid is null or n.id = $2)
          order by n.created_at limit 200`,
        [now, onlyId ?? null],
      )
    ).rows;
    let planned = 0;
    for (const n of due) {
      try {
        if (await this.plan(n, now)) planned++;
      } catch (e) {
        this.log?.error(e);
      }
    }
    const attempted = await this.sendDue(now, onlyId);
    return { planned, attempted };
  }

  private async plan(n: Record<string, any>, now: Date): Promise<boolean> {
    const t = tpl(n.type);
    const prefs = await loadPrefs(this.pool, n.user_id);
    if (!t.mandatory) {
      if (prefs.disabledTypes.includes(n.type)) {
        await this.pool.query(`update notifications set status = 'suppressed', planned_at = $2 where id = $1`, [n.id, now]);
        return false;
      }
      const until = quietUntil(prefs, now);
      if (until) {
        // Queue until the quiet window ends (F10-4). The inbox item is already visible.
        await this.pool.query('update notifications set deliver_after = $2 where id = $1', [n.id, until]);
        return false;
      }
    }
    const claimed = await this.pool.query(`update notifications set planned_at = $2 where id = $1 and planned_at is null returning id`, [n.id, now]);
    if (!claimed.rowCount) return false;

    const needsConsent = await consentRequired(this.pool, n.user_id);
    const consent = needsConsent ? await loadConsent(this.pool, n.user_id) : { push: true, sms: true };
    const wants = (ch: 'push' | 'sms') => consent[ch] === true && (t.mandatory || prefs.channels.includes(ch));
    const deliveries: { channel: 'push' | 'sms'; target: string }[] = [];
    if (wants('push')) {
      const tokens = (
        await this.pool.query(
          `select d.token from device_tokens d join sessions s on s.id = d.session_id
            where d.user_id = $1 and d.revoked_at is null and s.revoked_at is null and s.expires_at > now()`,
          [n.user_id],
        )
      ).rows;
      for (const tk of tokens) deliveries.push({ channel: 'push', target: tk.token });
    }
    // SMS is a fallback for time-sensitive types, used only when no push path exists (cost gate).
    if (deliveries.length === 0 && t.smsFallback && wants('sms') && !n.sms_to) deliveries.push({ channel: 'sms', target: n.phone });
    // An explicit SMS target (previous number after a phone change) is always notified in addition to push.
    if (n.sms_to && wants('sms')) deliveries.push({ channel: 'sms', target: n.sms_to });
    for (const d of deliveries) {
      await this.pool.query(`insert into notification_deliveries (notification_id, channel, target, next_attempt_at) values ($1,$2,$3,$4)`, [n.id, d.channel, d.target, now]);
    }
    await this.refreshStatus(n.id, now);
    return true;
  }

  private async sendDue(now: Date, onlyId?: string): Promise<number> {
    // Lease the rows so concurrent workers never double-send.
    const leased = (
      await this.pool.query(
        `update notification_deliveries d set next_attempt_at = $1::timestamptz + make_interval(secs => $3)
          where d.id in (
            select x.id from notification_deliveries x
             where x.status = 'pending' and x.next_attempt_at <= $1 and ($2::uuid is null or x.notification_id = $2)
             order by x.next_attempt_at limit 200 for update skip locked)
          returning d.*`,
        [now, onlyId ?? null, RETRY.leaseSeconds],
      )
    ).rows;
    const touched = new Set<string>();
    for (const d of leased) {
      const n = (await this.pool.query('select n.*, u.phone from notifications n join users u on u.id = n.user_id where n.id = $1', [d.notification_id])).rows[0];
      const prefs = await loadPrefs(this.pool, n.user_id);
      const text = renderExternal(n.type, prefs.locale);
      try {
        if (d.channel === 'push') {
          const dev = (await this.pool.query('select platform from device_tokens where token = $1', [d.target])).rows[0];
          await this.push.send({ token: d.target, platform: dev?.platform ?? 'android', title: text.title, body: text.body, data: { nid: n.id } });
        } else {
          await this.sms.send(d.target, text.body);
        }
        await this.pool.query(`update notification_deliveries set status = 'sent', attempts = attempts + 1, sent_at = $2, last_error = null where id = $1`, [d.id, now]);
      } catch (e) {
        const attempts = d.attempts + 1;
        const msg = (e instanceof Error ? e.message : String(e)).slice(0, 300);
        const final = attempts >= RETRY.maxAttempts;
        await this.pool.query(
          `update notification_deliveries set attempts = $2, last_error = $3, status = $4, next_attempt_at = $5 where id = $1`,
          [d.id, attempts, msg, final ? 'failed' : 'pending', new Date(now.getTime() + backoffSeconds(attempts) * 1000)],
        );
        if (final && d.channel === 'push') await this.smsFallbackAfterPush(n, now);
      }
      touched.add(d.notification_id);
    }
    for (const id of touched) await this.refreshStatus(id, now);
    return leased.length;
  }

  /** Push exhausted its retries: fall back to SMS if the type allows it and the user opted in. */
  private async smsFallbackAfterPush(n: Record<string, any>, now: Date) {
    const t = tpl(n.type);
    if (!t.smsFallback) return;
    const others = await this.pool.query(`select 1 from notification_deliveries where notification_id = $1 and (channel = 'sms' or status = 'pending')`, [n.id]);
    if (others.rowCount) return;
    const prefs = await loadPrefs(this.pool, n.user_id);
    const needsConsent = await consentRequired(this.pool, n.user_id);
    const consent = needsConsent ? await loadConsent(this.pool, n.user_id) : { push: true, sms: true };
    if (consent.sms !== true || !(t.mandatory || prefs.channels.includes('sms'))) return;
    await this.pool.query(`insert into notification_deliveries (notification_id, channel, target, next_attempt_at) values ($1,'sms',$2,$3)`, [n.id, n.sms_to ?? n.phone, now]);
  }

  /** Overall status: pending while any delivery is pending, sent if anything went out (or in-app only), else failed. */
  private async refreshStatus(id: string, now: Date) {
    await this.pool.query(
      `with agg as (
         select count(*) filter (where status = 'pending') as pending, count(*) filter (where status = 'sent') as sent, count(*) as total,
                coalesce(sum(attempts), 0) as attempts, (array_agg(last_error order by created_at desc) filter (where last_error is not null))[1] as last_error
           from notification_deliveries where notification_id = $1)
       update notifications n set
         status = case when n.status in ('suppressed') then n.status when agg.pending > 0 then 'pending' when agg.total = 0 or agg.sent > 0 then 'sent' else 'failed' end,
         sent_at = case when agg.pending = 0 and (agg.total = 0 or agg.sent > 0) then coalesce(n.sent_at, $2) else n.sent_at end,
         attempts = agg.attempts, last_error = agg.last_error
        from agg where n.id = $1`,
      [id, now],
    );
  }

  /** Scheduled work: reminder sources, due/queued deliveries, retries. Safe to run concurrently and repeatedly. */
  async runJobs(now = new Date()) {
    await dispatchDueReminders(this.pool, now, this);
    await dispatchGrantExpiring(this.pool, now, this);
    for (const [name, src] of this.sources) {
      try {
        for (const item of await src(this.pool, now)) await this.notify({ userId: item.userId, type: item.type, key: item.key, params: item.params }, now);
      } catch (e) {
        this.log?.error(Object.assign(new Error(`reminder source ${name} failed`), { cause: e }));
      }
    }
    return this.process(now);
  }
}

// ---------------------------------------------------------------------------------------------
// Lookups used by triggers
// ---------------------------------------------------------------------------------------------
/** The patient's account (if they have claimed their profile) and the clinic name for a care relationship. */
export async function relationshipRecipient(db: Db, relationshipId: string): Promise<{ userId: string; clinicName: string } | null> {
  const r = (
    await db.query(
      `select p.user_id, coalesce(w.name, '') as clinic_name from care_relationships r
         join patients p on p.id = r.patient_id join workspaces w on w.id = r.workspace_id where r.id = $1 and p.user_id is not null and r.status <> 'ended'`,
      [relationshipId],
    )
  ).rows[0];
  return r ? { userId: r.user_id, clinicName: r.clinic_name } : null;
}

const REMINDER_LEAD_HOURS = 24;

/** F04-7: reminders for scheduled appointments starting within the lead window. Idempotent per appointment time. */
export async function dispatchDueReminders(pool: pg.Pool, now: Date, notifier: Notifier): Promise<number> {
  const rows = (
    await pool.query(
      `select a.id, a.scheduled_at, p.user_id, coalesce(w.name, '') as clinic_name
         from appointments a join care_relationships r on r.id = a.care_relationship_id and r.status = 'active'
         join patients p on p.id = r.patient_id and p.user_id is not null join workspaces w on w.id = a.workspace_id
        where a.status = 'scheduled' and a.scheduled_at > $1 and a.scheduled_at <= $1::timestamptz + make_interval(hours => $2)
        order by a.scheduled_at limit 500`,
      [now, REMINDER_LEAD_HOURS],
    )
  ).rows;
  let n = 0;
  for (const a of rows) {
    const id = await notifier.notify(
      { userId: a.user_id, type: 'appointment_reminder', key: `appt-reminder:${a.id}:${new Date(a.scheduled_at).getTime()}`, params: { clinicName: a.clinic_name, appointmentId: a.id, appointmentAt: new Date(a.scheduled_at).toISOString() } },
      now,
    );
    if (id) n++;
  }
  return n;
}

/** F08-5: tell both sides once when a grant is about to expire. */
export async function dispatchGrantExpiring(pool: pg.Pool, now: Date, notifier: Notifier): Promise<number> {
  const rows = (
    await pool.query(
      `select g.id, g.granted_by, w.owner_id from sharing_grants g join workspaces w on w.id = g.recipient_workspace_id
        where g.revoked_at is null and g.expires_at > $1 and g.expires_at <= $1::timestamptz + make_interval(days => $2) limit 500`,
      [now, config.sharing.expiringSoonDays],
    )
  ).rows;
  let n = 0;
  for (const g of rows) {
    for (const [who, userId] of [['patient', g.granted_by], ['clinic', g.owner_id]] as const) {
      if (await notifier.notify({ userId, type: 'grant_expiring', key: `grant-expiring:${g.id}:${who}`, params: { grantId: g.id } }, now)) n++;
    }
  }
  return n;
}

export function assertKnownTypes(types: string[]) {
  for (const t of types) {
    if (!NOTIFICATION_TYPES.includes(t as NotificationType)) throw badRequest('unknown_type', `Unknown notification type: ${t}`);
    if ((TEMPLATES as Record<string, Template>)[t]?.mandatory) throw badRequest('mandatory_notice', 'Security notices cannot be disabled');
  }
}
