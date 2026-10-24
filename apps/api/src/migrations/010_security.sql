-- Spec 11: audit result/device, break-glass access, chain verification runs, data-subject operations, legal hold.
alter table audit_log
  add column result text not null default 'success' check (result in ('success', 'denied')),
  add column device text;
create index audit_action_idx on audit_log (chain_key, action, seq desc);

-- Time-boxed, justified access of a platform admin to one workspace's audit log (F11-3).
create table break_glass_access (
  id uuid primary key default gen_random_uuid(),
  admin_id uuid not null references users(id),
  workspace_id uuid not null references workspaces(id),
  justification text not null check (char_length(justification) >= 15),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);
create index break_glass_active_idx on break_glass_access (admin_id, workspace_id, expires_at);

-- Results of the scheduled / on-demand chain verification job (F11-1).
create table audit_verifications (
  id uuid primary key default gen_random_uuid(),
  ran_at timestamptz not null default now(),
  triggered_by text not null,               -- 'job' or the admin's user id
  chains_checked int not null,
  entries_checked int not null,
  valid boolean not null,
  broken jsonb not null default '[]'
);

-- F11-7: patient correction requests. They never edit a clinical record; the clinic decides and amends through the normal flow.
create table correction_requests (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references patients(id),
  requested_by uuid not null references users(id),
  workspace_id uuid not null references workspaces(id),
  target_type text not null check (target_type in ('encounter', 'document', 'relationship')),
  target_id uuid not null,
  description text not null check (char_length(description) between 5 and 2000),
  status text not null default 'open' check (status in ('open', 'resolved', 'rejected')),
  resolution_note text,
  resolved_by uuid references users(id),
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);
create index correction_workspace_idx on correction_requests (workspace_id, status, created_at desc);
create index correction_patient_idx on correction_requests (patient_id, created_at desc);

-- Data export log, used for rate limiting and as an audit cross-check.
create table data_exports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id),
  created_at timestamptz not null default now()
);
create index data_exports_user_idx on data_exports (user_id, created_at desc);

-- F11-7: a legally mandated retention override. While set, nothing about the record can be deleted or erased.
alter table care_relationships
  add column legal_hold boolean not null default false,
  add column legal_hold_reason text,
  add column legal_hold_set_by uuid references users(id),
  add column legal_hold_set_at timestamptz;
