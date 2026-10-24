-- Spec 10: notifications. The inbox row is the source of truth; push/SMS go out through notification_deliveries.
create table notification_preferences (
  user_id uuid primary key references users(id),
  locale text not null default 'ar' check (locale in ('ar', 'en')),
  channels text[] not null default '{push,sms}',      -- external channels the user accepts; in-app is always on
  quiet_start text check (quiet_start ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  quiet_end text check (quiet_end ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  timezone text not null default 'Africa/Cairo',
  disabled_types text[] not null default '{}',         -- never contains a mandatory (security) type; enforced in the API
  updated_at timestamptz not null default now()
);

-- F10-5: consent is an append-only record; the newest row per (user, channel) wins.
create table notification_consents (
  id bigserial primary key,
  user_id uuid not null references users(id),
  channel text not null check (channel in ('push', 'sms')),
  granted boolean not null,
  source text not null default 'app',
  ip text,
  recorded_at timestamptz not null default now()
);
create index notification_consents_user_idx on notification_consents (user_id, channel, id desc);

create table device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id),
  session_id uuid references sessions(id),
  token text not null unique,
  platform text not null check (platform in ('android', 'ios', 'web')),
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  revoked_at timestamptz
);
create index device_tokens_user_idx on device_tokens (user_id) where revoked_at is null;

create table notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id),
  type text not null,
  template_key text not null,
  params jsonb not null default '{}',                  -- non-clinical references only (whitelisted per template)
  idempotency_key text not null unique,
  status text not null default 'pending' check (status in ('pending', 'sent', 'failed', 'suppressed')),
  deliver_after timestamptz not null default now(),    -- quiet hours and scheduled sends
  planned_at timestamptz,                              -- set once channels were chosen
  sms_to text,                                         -- optional explicit SMS target (e.g. the old number after a phone change)
  attempts int not null default 0,
  last_error text,
  sent_at timestamptz,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index notifications_inbox_idx on notifications (user_id, created_at desc, id desc) where status <> 'suppressed';
create index notifications_due_idx on notifications (deliver_after) where status = 'pending';

create table notification_deliveries (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null references notifications(id) on delete cascade,
  channel text not null check (channel in ('push', 'sms')),
  target text not null,                                -- device token or phone number
  status text not null default 'pending' check (status in ('pending', 'sent', 'failed')),
  attempts int not null default 0,
  next_attempt_at timestamptz not null default now(),
  last_error text,
  sent_at timestamptz,
  created_at timestamptz not null default now()
);
create index notification_deliveries_due_idx on notification_deliveries (next_attempt_at) where status = 'pending';
create index notification_deliveries_notification_idx on notification_deliveries (notification_id);
