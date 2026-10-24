-- Spec 09: follow-up plans, requested measurements and patient-reported submissions.
create table followup_plans (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(id),
  care_relationship_id uuid not null references care_relationships(id),
  created_by uuid not null references users(id),
  next_visit_date date,
  instructions text not null default '',
  start_date date not null,
  end_date date,
  status text not null default 'active' check (status in ('active', 'closed')),
  current_version int not null default 1,
  closed_at timestamptz,
  closed_by uuid references users(id),
  close_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_date is null or end_date >= start_date)
);
create index followup_plans_relationship_idx on followup_plans (care_relationship_id, created_at desc);
create index followup_plans_workspace_idx on followup_plans (workspace_id, status);

-- Measurements the doctor asks for. `kind` is a known vital key (packages/shared vitals) or null for a custom name.
-- Edits never delete a measurement that has submissions: it is deactivated instead.
create table followup_measurements (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references followup_plans(id),
  kind text,
  name text not null,
  unit text not null default '',
  frequency text not null check (frequency in ('daily', 'weekly', 'custom')),
  interval_days int not null check (interval_days between 1 and 90),
  normal_min numeric,
  normal_max numeric,
  active boolean not null default true,
  position bigint generated always as identity,   -- stable display order
  created_at timestamptz not null default now(),
  check (normal_min is null or normal_max is null or normal_min <= normal_max)
);
create index followup_measurements_plan_idx on followup_measurements (plan_id);

-- One immutable snapshot per plan version (F09-5): version 1 is the creation, each edit/close appends.
create table followup_plan_versions (
  plan_id uuid not null references followup_plans(id),
  version int not null,
  edited_by uuid not null references users(id),
  change text not null check (change in ('created', 'edited', 'closed')),
  snapshot jsonb not null,
  created_at timestamptz not null default now(),
  primary key (plan_id, version)
);

-- Patient-reported values. Always source = patient; never verified; kept apart from clinician observations.
create table followup_submissions (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references followup_plans(id),
  measurement_id uuid not null references followup_measurements(id),
  workspace_id uuid not null references workspaces(id),
  care_relationship_id uuid not null references care_relationships(id),
  patient_id uuid not null references patients(id),
  value numeric not null,
  measured_at timestamptz not null,
  note text not null default '',
  document_id uuid references documents(id),
  source text not null default 'patient' check (source = 'patient'),
  created_by uuid not null references users(id),
  created_at timestamptz not null default now()
);
create index followup_submissions_measurement_idx on followup_submissions (measurement_id, measured_at desc);
create index followup_submissions_plan_idx on followup_submissions (plan_id, created_at desc);
