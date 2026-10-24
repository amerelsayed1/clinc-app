-- Spec 01: doctor MFA (TOTP + recovery codes), MFA login challenges, phone change.
alter table users
  add column totp_secret_enc text,
  add column totp_pending_enc text,
  add column totp_last_step bigint,
  add column mfa_enabled_at timestamptz;

create table mfa_challenges (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id),
  token_hash text not null unique,
  device_name text,
  ip text,
  attempts int not null default 0,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);

create table mfa_recovery_codes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id),
  code_hash text not null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);
create index mfa_recovery_user_idx on mfa_recovery_codes (user_id);
