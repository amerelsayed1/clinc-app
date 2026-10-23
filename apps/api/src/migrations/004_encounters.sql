create table encounters (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(id),
  care_relationship_id uuid not null references care_relationships(id),
  appointment_id uuid references appointments(id),
  author_id uuid not null references users(id),
  encounter_date timestamptz not null default now(),
  status text not null default 'draft' check (status in ('draft', 'signed', 'discarded')),
  revision int not null default 1,          -- optimistic concurrency for draft autosave
  current_version int not null default 1,
  signed_at timestamptz,
  published_version int,                    -- version the patient may see (F05-10)
  published_at timestamptz,
  published_by uuid references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index encounters_appointment_idx on encounters (appointment_id) where appointment_id is not null and status <> 'discarded';
create index encounters_patient_idx on encounters (care_relationship_id, encounter_date desc);
create index encounters_ws_idx on encounters (workspace_id, encounter_date desc);

-- Content is versioned. A draft edits version 1 in place; once the encounter is signed, versions are
-- immutable and corrections are new versions (amendments) with a reason (F05-5, RULE-002).
create table encounter_versions (
  encounter_id uuid not null references encounters(id),
  version int not null,
  chief_complaint text not null default '',
  history text not null default '',
  diagnosis text not null default '',
  plan text not null default '',
  private_notes text not null default '',
  prescriptions jsonb not null default '[]',
  author_id uuid not null references users(id),
  amendment_reason text,
  changed_fields text[] not null default '{}',
  created_at timestamptz not null default now(),
  primary key (encounter_id, version)
);

create function encounter_versions_guard() returns trigger as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'encounter versions cannot be deleted';
  end if;
  if (select status from encounters where id = old.encounter_id) <> 'draft' then
    raise exception 'encounter versions are immutable once signed; create an amendment';
  end if;
  return new;
end;
$$ language plpgsql;
create trigger encounter_versions_no_change before update or delete on encounter_versions
  for each row execute function encounter_versions_guard();

-- Vitals are separate, attributed observations (F05-3). Mistakes are voided, never edited.
create table observations (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(id),
  care_relationship_id uuid not null references care_relationships(id),
  encounter_id uuid not null references encounters(id),
  kind text not null,
  value numeric(8, 2) not null,
  measured_at timestamptz not null default now(),
  recorded_by uuid not null references users(id),
  recorded_role text not null,
  created_at timestamptz not null default now(),
  voided_at timestamptz,
  voided_by uuid references users(id),
  void_reason text
);
create index observations_patient_idx on observations (care_relationship_id, kind, measured_at);
create index observations_encounter_idx on observations (encounter_id);
