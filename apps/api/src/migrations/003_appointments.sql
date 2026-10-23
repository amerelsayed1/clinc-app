-- Working hours are local to the workspace time zone; days with no ranges are closed.
-- Default (assumption, editable per clinic): Saturday-Thursday 09:00-17:00, Friday closed.
alter table workspaces
  add column timezone text not null default 'Africa/Cairo',
  add column slot_minutes int not null default 15 check (slot_minutes between 5 and 120),
  add column working_hours jsonb not null default
    '{"sat":[{"start":"09:00","end":"17:00"}],"sun":[{"start":"09:00","end":"17:00"}],"mon":[{"start":"09:00","end":"17:00"}],"tue":[{"start":"09:00","end":"17:00"}],"wed":[{"start":"09:00","end":"17:00"}],"thu":[{"start":"09:00","end":"17:00"}],"fri":[]}';

create table appointments (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(id),
  care_relationship_id uuid not null references care_relationships(id),
  scheduled_at timestamptz not null,
  duration_minutes int not null check (duration_minutes between 5 and 480),
  type text not null default 'new' check (type in ('new', 'follow_up')),
  is_walk_in boolean not null default false,
  reason text,
  status text not null default 'scheduled'
    check (status in ('scheduled', 'checked_in', 'in_consultation', 'completed', 'cancelled', 'no_show')),
  checked_in_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text,
  created_by uuid references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index appointments_ws_time_idx on appointments (workspace_id, scheduled_at);
create index appointments_patient_idx on appointments (care_relationship_id, scheduled_at desc);
