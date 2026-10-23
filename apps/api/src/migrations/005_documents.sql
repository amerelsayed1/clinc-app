-- Placeholder plan quota (spec 06 F06-7); real per-plan limits arrive with billing.
alter table workspaces add column storage_quota_bytes bigint not null default 524288000;

create table documents (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references patients(id),
  -- Clinic uploads belong to a workspace + care relationship; patient uploads belong to the patient only.
  workspace_id uuid references workspaces(id),
  care_relationship_id uuid references care_relationships(id),
  encounter_id uuid references encounters(id),
  source text not null check (source in ('clinician', 'staff', 'patient')),
  uploaded_by uuid not null references users(id),
  uploader_role text not null,
  category text not null check (category in ('prescription', 'lab_result', 'imaging', 'report', 'administrative', 'other')),
  title text not null default '',
  notes text not null default '',
  document_date date,
  status text not null default 'available' check (status in ('available', 'deleted')),
  total_bytes bigint not null,
  published_at timestamptz,          -- clinic documents the doctor chose to show the patient
  published_by uuid references users(id),
  deleted_at timestamptz,
  deleted_by uuid references users(id),
  delete_reason text,
  created_at timestamptz not null default now(),
  check ((source = 'patient') = (workspace_id is null))
);
create index documents_relationship_idx on documents (care_relationship_id, created_at desc);
create index documents_patient_idx on documents (patient_id, created_at desc);
create index documents_workspace_idx on documents (workspace_id);
create index documents_encounter_idx on documents (encounter_id);

-- One row per captured page/file. Bytes live in object storage, encrypted with a per-file data key
-- that is itself wrapped by the master key.
create table document_pages (
  document_id uuid not null references documents(id),
  page int not null,
  storage_key text not null unique,
  mime text not null,
  size_bytes int not null,
  sha256 text not null,
  wrapped_key text not null,
  original_name text,
  primary key (document_id, page)
);

-- A patient sending one of their uploads to a clinic they are connected to. Revocable; spec 08 generalises this.
create table document_shares (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references documents(id),
  care_relationship_id uuid not null references care_relationships(id),
  shared_by uuid not null references users(id),
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  unique (document_id, care_relationship_id)
);

-- Clinician review of a patient-submitted document. Adds a verification entry; never alters the original (F06-4).
create table document_reviews (
  document_id uuid not null references documents(id),
  workspace_id uuid not null references workspaces(id),
  reviewed_by uuid not null references users(id),
  note text not null default '',
  created_at timestamptz not null default now(),
  primary key (document_id, workspace_id)
);

-- Append-only record of every file view, usable as the patient-facing access log in spec 08.
create table document_access (
  id bigserial primary key,
  document_id uuid not null references documents(id),
  accessor_user_id uuid not null references users(id),
  workspace_id uuid references workspaces(id),
  page int not null,
  created_at timestamptz not null default now()
);
create index document_access_doc_idx on document_access (document_id, created_at desc);
create trigger document_access_no_update before update or delete on document_access
  for each row execute function audit_log_immutable();
