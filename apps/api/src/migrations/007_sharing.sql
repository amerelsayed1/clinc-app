-- Spec 08: grants, access requests and the patient-visible access log.
create table sharing_grants (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references patients(id),
  recipient_workspace_id uuid not null references workspaces(id),
  granted_by uuid not null references users(id),
  scope jsonb not null,                  -- {items:[{type,id}]} | {categories:[..], from?, to?}; immutable after creation (F08-2)
  purpose text not null default '',
  request_id uuid,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  revoked_by uuid references users(id),
  expiry_recorded_at timestamptz,        -- set once the expiry audit event has been written
  created_at timestamptz not null default now()
);
create index sharing_grants_patient_idx on sharing_grants (patient_id, created_at desc);
create index sharing_grants_recipient_idx on sharing_grants (recipient_workspace_id, expires_at);

create table access_requests (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references patients(id),
  workspace_id uuid not null references workspaces(id),   -- requesting clinic
  requested_by uuid not null references users(id),
  scope jsonb not null,
  purpose text not null,
  requested_days int not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'denied', 'cancelled', 'expired')),
  grant_id uuid references sharing_grants(id),
  decided_at timestamptz,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create unique index access_requests_one_pending_idx on access_requests (patient_id, workspace_id) where status = 'pending';
create index access_requests_patient_idx on access_requests (patient_id, status, created_at desc);
alter table sharing_grants add constraint sharing_grants_request_fk foreign key (request_id) references access_requests(id);

-- Every view of a shared item, readable by the patient (F08-7). Append-only.
create table shared_access_log (
  id bigserial primary key,
  grant_id uuid not null references sharing_grants(id),
  patient_id uuid not null references patients(id),
  workspace_id uuid not null references workspaces(id),
  accessor_user_id uuid not null references users(id),
  item_type text not null check (item_type in ('document', 'encounter')),
  item_id uuid not null,
  created_at timestamptz not null default now()
);
create index shared_access_log_patient_idx on shared_access_log (patient_id, created_at desc);
create index shared_access_log_grant_idx on shared_access_log (grant_id, created_at desc);
create trigger shared_access_log_no_update before update or delete on shared_access_log
  for each row execute function audit_log_immutable();
