-- Global patient identity is deliberately minimal (phone + optional linked account).
-- Demographics live on the per-workspace care relationship, so one clinic's data never leaks to another (RULE-003).
create table patients (
  id uuid primary key default gen_random_uuid(),
  phone text not null unique,
  user_id uuid unique references users(id),
  claimed_at timestamptz,
  created_at timestamptz not null default now()
);

alter table workspaces add column next_patient_number int not null default 1;

create table care_relationships (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references patients(id),
  workspace_id uuid not null references workspaces(id),
  patient_number int not null,
  full_name text not null,
  date_of_birth date,
  sex text check (sex in ('male', 'female')),
  status text not null check (status in ('invited', 'active', 'ended')),
  ended_by text check (ended_by in ('workspace', 'patient')),
  ended_at timestamptz,
  created_by uuid references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (patient_id, workspace_id),
  unique (workspace_id, patient_number)
);
create index care_relationships_ws_idx on care_relationships (workspace_id, status, created_at desc);
