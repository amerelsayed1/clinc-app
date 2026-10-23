create table users (
  id uuid primary key default gen_random_uuid(),
  phone text not null unique,
  full_name text,
  is_platform_admin boolean not null default false,
  created_at timestamptz not null default now()
);

create table doctor_profiles (
  user_id uuid primary key references users(id),
  license_number text not null,
  verification_status text not null default 'pending'
    check (verification_status in ('pending', 'verified', 'rejected')),
  verification_note text,
  verified_by uuid references users(id),
  verified_at timestamptz,
  created_at timestamptz not null default now()
);

create table otp_codes (
  id uuid primary key default gen_random_uuid(),
  phone text not null,
  code_hash text not null,
  expires_at timestamptz not null,
  attempts int not null default 0,
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);
create index otp_codes_phone_idx on otp_codes (phone, created_at desc);

create table sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id),
  refresh_hash text not null,
  prev_refresh_hash text,
  device_name text,
  ip text,
  created_at timestamptz not null default now(),
  last_used_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz
);
create index sessions_user_idx on sessions (user_id);
create index sessions_refresh_idx on sessions (refresh_hash);

-- MVP: one doctor owns one workspace; schema allows many members and many workspaces per user.
create table workspaces (
  id uuid primary key default gen_random_uuid(),
  name text,
  owner_id uuid not null references users(id),
  created_at timestamptz not null default now()
);
create unique index workspaces_owner_idx on workspaces (owner_id);

create table memberships (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(id),
  user_id uuid not null references users(id),
  role text not null check (role in ('doctor', 'nurse', 'receptionist')),
  denied_permissions text[] not null default '{}',
  status text not null default 'active' check (status in ('active', 'suspended', 'removed')),
  created_at timestamptz not null default now(),
  unique (workspace_id, user_id)
);
create index memberships_user_idx on memberships (user_id);

create table invitations (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(id),
  phone text not null,
  role text not null check (role in ('nurse', 'receptionist')),
  code_hash text not null unique,
  invited_by uuid not null references users(id),
  expires_at timestamptz not null,
  accepted_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

-- Append-only, hash-chained per chain_key (workspace id, or 'global' for auth events).
create table audit_log (
  id bigserial primary key,
  chain_key text not null,
  seq int not null,
  workspace_id uuid references workspaces(id),
  actor_id uuid references users(id),
  actor_role text,
  action text not null,
  target_type text,
  target_id text,
  metadata jsonb not null default '{}',
  ip text,
  created_at timestamptz not null,
  prev_hash text not null,
  hash text not null,
  unique (chain_key, seq)
);
create index audit_workspace_idx on audit_log (workspace_id, seq desc);

create function audit_log_immutable() returns trigger as $$
begin
  raise exception 'audit_log is append-only';
end;
$$ language plpgsql;
create trigger audit_log_no_update before update or delete on audit_log
  for each row execute function audit_log_immutable();
