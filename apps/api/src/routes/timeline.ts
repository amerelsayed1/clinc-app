import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { z } from 'zod';
import { VITAL_KINDS } from '@clinic/shared';
import { writeAudit } from '../audit.js';
import { authenticate, workspaceGuard } from '../auth.js';
import { tx } from '../db.js';
import { badRequest, notFound } from '../errors.js';
import { candidates, matches, type Scope } from './sharing.js';

/*
 * Spec 07: the timeline is a read-model. Each entry source is a small adapter that returns SQL branches over the
 * same fixed column list; the branches are UNION ALLed, filtered, ordered and keyset-paginated in one query.
 *
 * Every branch receives the same positional parameters, so scope is enforced inside the SQL of each source:
 *   $1 patient id   $2 care relationship id (doctor view)   $3 workspace id (doctor view)
 *   $4 encounter ids shared to this workspace via active grants   $5 document ids shared likewise
 * Adapters must never read content outside that scope, and must only select fields the viewer may see.
 */

export const TIMELINE_TYPES = ['encounter', 'prescription', 'document', 'observation', 'followup', 'appointment', 'shared_notice'] as const;
export type TimelineType = (typeof TIMELINE_TYPES)[number];

export interface TimelineCtx {
  mode: 'doctor' | 'patient';
  role: string; // workspace role in doctor mode
  sharedEncounters: string[];
  sharedDocuments: string[];
}
export interface TimelineSource {
  name: string;
  branches(ctx: TimelineCtx): string[];
}

interface SelectParts {
  type: string;
  id: string;
  refType: string;
  ts: string;
  title: string;
  summary: string;
  search: string;
  authorId: string;
  authorName: string;
  workspaceId: string;
  workspaceName: string;
  tag: 'own' | 'shared' | 'sent' | 'patient' | string; // provenance relative to the viewer
  version: string;
  versionCount: string;
  badge: string;
  extra?: string;
}
/** Builds the fixed column list every branch must produce; callers append `from ... where ...`. */
export const tlSelect = (p: SelectParts) =>
  `select ${p.type}::text as type, ${p.id}::uuid as id, ${p.refType}::text as ref_type, ${p.ts}::timestamptz as ts, ${p.title}::text as title, ${p.summary}::text as summary,
          ${p.search}::text as search, ${p.authorId}::uuid as author_id, ${p.authorName}::text as author_name, ${p.workspaceId}::uuid as workspace_id,
          ${p.workspaceName}::text as workspace_name, ${p.tag}::text as tag, ${p.version}::int as version, ${p.versionCount}::int as version_count,
          ${p.badge}::text as badge, ${p.extra ?? `'{}'`}::jsonb as extra`;

const rxText = `(select string_agg(concat_ws(' ', x->>'medication', x->>'dose', x->>'frequency', x->>'duration', x->>'notes'), ' ') from jsonb_array_elements(v.prescriptions) x)`;
const rxNames = `(select string_agg(x->>'medication', ', ') from jsonb_array_elements(v.prescriptions) x)`;
const catLabel = (c: string) => `initcap(replace(${c}, '_', ' '))`;

interface EncSource {
  cond: string;
  ver: 'current_version' | 'published_version';
  tag: string;
  own: boolean;
}
function encounterSources(ctx: TimelineCtx): EncSource[] {
  if (ctx.mode === 'patient') {
    return [{ cond: `r.patient_id = $1::uuid and e.status = 'signed' and e.published_version is not null`, ver: 'published_version', tag: 'patient', own: false }];
  }
  const out: EncSource[] = [{ cond: `e.care_relationship_id = $2::uuid and e.workspace_id = $3::uuid and e.status = 'signed'`, ver: 'current_version', tag: 'own', own: true }];
  // Shared consultations expose the published version only, and never history or private notes.
  if (ctx.sharedEncounters.length) {
    out.push({ cond: `e.id = any($4::uuid[]) and e.status = 'signed' and e.published_version is not null and e.workspace_id <> $3::uuid`, ver: 'published_version', tag: 'shared', own: false });
  }
  return out;
}
const encFrom = (s: EncSource) => `from encounters e join care_relationships r on r.id = e.care_relationship_id
  join encounter_versions v on v.encounter_id = e.id and v.version = e.${s.ver} join users au on au.id = e.author_id join workspaces w on w.id = e.workspace_id`;

const encounterSource: TimelineSource = {
  name: 'encounters',
  branches(ctx) {
    const out: string[] = [];
    for (const s of encounterSources(ctx)) {
      const privateText = s.own && ctx.role === 'doctor' ? 'v.private_notes' : `''`;
      const historyText = s.own ? 'v.history' : `''`;
      const ver = `e.${s.ver}`;
      out.push(
        `${tlSelect({
          type: `'encounter'`, id: 'e.id', refType: `'encounter'`, ts: 'e.encounter_date',
          title: `coalesce(nullif(trim(v.chief_complaint), ''), 'Consultation')`,
          summary: `left(concat_ws(' · ', nullif(trim(v.diagnosis), ''), nullif(trim(v.plan), '')), 240)`,
          search: `concat_ws(' ', v.chief_complaint, ${historyText}, v.diagnosis, v.plan, ${privateText}, ${rxText})`,
          authorId: 'e.author_id', authorName: 'au.full_name', workspaceId: 'w.id', workspaceName: 'w.name', tag: `'${s.tag}'`,
          version: ver, versionCount: ver, badge: `'clinician_authored'`,
          extra: `jsonb_build_object('appointmentId', e.appointment_id, 'published', e.published_version is not null)`,
        })} ${encFrom(s)} where ${s.cond}`,
        `${tlSelect({
          type: `'prescription'`, id: 'e.id', refType: `'encounter'`, ts: 'e.encounter_date', title: `'Prescription'`,
          summary: `left(${rxNames}, 240)`, search: rxText,
          authorId: 'e.author_id', authorName: 'au.full_name', workspaceId: 'w.id', workspaceName: 'w.name', tag: `'${s.tag}'`,
          version: ver, versionCount: ver, badge: `'clinician_authored'`,
          extra: `jsonb_build_object('items', jsonb_array_length(v.prescriptions))`,
        })} ${encFrom(s)} where ${s.cond} and jsonb_array_length(v.prescriptions) > 0`,
        // Vitals of the encounter, one entry per encounter. Voided readings are excluded.
        `${tlSelect({
          type: `'observation'`, id: 'e.id', refType: `'encounter'`, ts: 'min(o.measured_at)', title: `'Vitals'`,
          summary: `string_agg(o.kind || '=' || o.value::float8::text, '|' order by o.kind)`, search: `string_agg(o.kind, ' ')`,
          authorId: 'e.author_id', authorName: 'au.full_name', workspaceId: 'w.id', workspaceName: 'w.name', tag: `'${s.tag}'`,
          version: `e.${s.ver}`, versionCount: `e.${s.ver}`, badge: `'clinician_authored'`,
        })} from encounters e join care_relationships r on r.id = e.care_relationship_id join users au on au.id = e.author_id join workspaces w on w.id = e.workspace_id
          join observations o on o.encounter_id = e.id and o.voided_at is null
         where ${s.cond} group by e.id, au.id, w.id`,
      );
    }
    return out;
  },
};

const docSelect = (tag: string, fromWhere: string, reviewScope: string) =>
  `${tlSelect({
    type: `case when d.category = 'prescription' then 'prescription' else 'document' end`, id: 'd.id', refType: `'document'`,
    ts: `coalesce(d.document_date::timestamp at time zone 'UTC', d.created_at)`,
    title: `coalesce(nullif(trim(d.title), ''), ${catLabel('d.category')})`,
    summary: `left(concat_ws(' · ', ${catLabel('d.category')}, nullif(trim(d.notes), '')), 240)`,
    search: `concat_ws(' ', d.title, d.notes)`,
    authorId: 'd.uploaded_by', authorName: 'u.full_name', workspaceId: 'd.workspace_id', workspaceName: 'w.name', tag,
    version: '1', versionCount: '1',
    badge: `case when d.source = 'patient' then (case when exists (select 1 from document_reviews rv where rv.document_id = d.id ${reviewScope}) then 'reviewed' else 'patient_submitted' end) else 'clinician_authored' end`,
    extra: `jsonb_build_object('category', d.category, 'source', d.source, 'encounterId', d.encounter_id, 'published', d.published_at is not null, 'pages', (select count(*) from document_pages p where p.document_id = d.id))`,
  })} from documents d join users u on u.id = d.uploaded_by left join workspaces w on w.id = d.workspace_id where d.status = 'available' and d.category <> 'administrative' and ${fromWhere}`;

const documentSource: TimelineSource = {
  name: 'documents',
  branches(ctx) {
    if (ctx.mode === 'patient') {
      return [docSelect(`'patient'`, `d.patient_id = $1::uuid and (d.source = 'patient' or d.published_at is not null)`, '')];
    }
    const out = [
      docSelect(`'own'`, `d.care_relationship_id = $2::uuid and d.workspace_id = $3::uuid`, 'and rv.workspace_id = $3::uuid'),
      // Patient uploads the patient sent to this clinic (document_shares); revoked sends disappear.
      docSelect(
        `'sent'`,
        `d.source = 'patient' and exists (select 1 from document_shares s join care_relationships sr on sr.id = s.care_relationship_id
            where s.document_id = d.id and s.care_relationship_id = $2::uuid and sr.workspace_id = $3::uuid and s.revoked_at is null and sr.status <> 'ended')`,
        'and rv.workspace_id = $3::uuid',
      ),
    ];
    if (ctx.sharedDocuments.length) {
      out.push(
        docSelect(
          `'shared'`,
          `d.id = any($5::uuid[]) and d.patient_id = $1::uuid and d.workspace_id is distinct from $3::uuid
           and not exists (select 1 from document_shares s join care_relationships sr on sr.id = s.care_relationship_id
                            where s.document_id = d.id and s.care_relationship_id = $2::uuid and s.revoked_at is null)`,
          'and rv.workspace_id = $3::uuid',
        ),
      );
    }
    return out;
  },
};

const appointmentSource: TimelineSource = {
  name: 'appointments',
  branches(ctx) {
    const cond = ctx.mode === 'patient' ? `r.patient_id = $1::uuid and r.status in ('active', 'ended')` : `a.care_relationship_id = $2::uuid and a.workspace_id = $3::uuid`;
    return [
      `${tlSelect({
        type: `'appointment'`, id: 'a.id', refType: `'appointment'`, ts: 'a.scheduled_at',
        title: `case a.type when 'follow_up' then 'Follow-up appointment' else 'Appointment' end`,
        summary: `left(concat_ws(' · ', ${catLabel('a.status')}, nullif(trim(a.reason), '')), 240)`,
        search: `concat_ws(' ', a.reason, ${catLabel('a.status')})`,
        authorId: 'wo.id', authorName: 'wo.full_name', workspaceId: 'w.id', workspaceName: 'w.name', tag: ctx.mode === 'patient' ? `'patient'` : `'own'`,
        version: '1', versionCount: '1', badge: `'clinician_authored'`,
        extra: `jsonb_build_object('status', a.status, 'durationMinutes', a.duration_minutes)`,
      })} from appointments a join care_relationships r on r.id = a.care_relationship_id join workspaces w on w.id = a.workspace_id join users wo on wo.id = w.owner_id where ${cond}`,
    ];
  },
};

const noticeSource: TimelineSource = {
  name: 'shared_notices',
  branches(ctx) {
    const scopeText = `case when g.scope ? 'items' then (jsonb_array_length(g.scope->'items'))::text || ' selected record(s)'
                             else 'Categories: ' || (select string_agg(initcap(replace(x, '_', ' ')), ', ') from jsonb_array_elements_text(g.scope->'categories') x) end`;
    if (ctx.mode === 'patient') {
      return [
        `${tlSelect({
          type: `'shared_notice'`, id: 'g.id', refType: `'grant'`, ts: 'g.created_at', title: `'You shared records with ' || w.name`,
          summary: `left(${scopeText} || ' · ' || (case when g.revoked_at is not null then 'Revoked' when g.expires_at <= now() then 'Expired' else 'Active' end), 240)`,
          search: `concat_ws(' ', w.name, g.purpose)`,
          authorId: 'p.user_id', authorName: 'pu.full_name', workspaceId: 'w.id', workspaceName: 'w.name', tag: `'patient'`,
          version: '1', versionCount: '1', badge: `'patient_submitted'`,
          extra: `jsonb_build_object('expiresAt', g.expires_at, 'revokedAt', g.revoked_at)`,
        })} from sharing_grants g join patients p on p.id = g.patient_id left join users pu on pu.id = p.user_id join workspaces w on w.id = g.recipient_workspace_id where g.patient_id = $1::uuid`,
      ];
    }
    return [
      `${tlSelect({
        type: `'shared_notice'`, id: 'g.id', refType: `'grant'`, ts: 'g.created_at', title: `'Patient shared records with this clinic'`,
        summary: `left(${scopeText}, 240)`, search: `coalesce(g.purpose, '')`,
        authorId: 'p.user_id', authorName: 'pu.full_name', workspaceId: 'null', workspaceName: 'null', tag: `'notice'`,
        version: '1', versionCount: '1', badge: `'patient_submitted'`,
        extra: `jsonb_build_object('expiresAt', g.expires_at, 'purpose', g.purpose)`,
      })} from sharing_grants g join patients p on p.id = g.patient_id left join users pu on pu.id = p.user_id
          where g.patient_id = $1::uuid and g.recipient_workspace_id = $3::uuid and g.revoked_at is null and g.expires_at > now()`,
    ];
  },
};

// Spec 09 (migration 008): plan events and patient-submitted measurements. Not shareable, so own/patient scope only.
const followupSource: TimelineSource = {
  name: 'followups',
  branches(ctx) {
    const patient = ctx.mode === 'patient';
    const tag = patient ? `'patient'` : `'own'`;
    const planCond = patient ? `r.patient_id = $1::uuid and r.status in ('active', 'ended')` : `f.care_relationship_id = $2::uuid and f.workspace_id = $3::uuid`;
    const subCond = patient ? `s.patient_id = $1::uuid` : `s.care_relationship_id = $2::uuid and s.workspace_id = $3::uuid`;
    return [
      `${tlSelect({
        type: `'followup'`, id: 'f.id', refType: `'followup_plan'`, ts: 'f.created_at', title: `'Follow-up plan'`,
        summary: `left(concat_ws(' · ', nullif(trim(f.instructions), ''), case when f.next_visit_date is not null then 'Next visit ' || f.next_visit_date::text end), 240)`,
        search: `f.instructions`,
        authorId: 'f.created_by', authorName: 'cu.full_name', workspaceId: 'w.id', workspaceName: 'w.name', tag,
        version: 'f.current_version', versionCount: 'f.current_version', badge: `'clinician_authored'`,
        extra: `jsonb_build_object('event', 'plan', 'status', f.status, 'startDate', f.start_date, 'endDate', f.end_date)`,
      })} from followup_plans f join care_relationships r on r.id = f.care_relationship_id join workspaces w on w.id = f.workspace_id join users cu on cu.id = f.created_by where ${planCond}`,
      `${tlSelect({
        type: `'followup'`, id: 's.id', refType: `'followup_submission'`, ts: 's.measured_at',
        title: `m.name || ': ' || s.value::float8::text || case when m.unit <> '' then ' ' || m.unit else '' end`,
        summary: `left(nullif(trim(s.note), ''), 240)`, search: `concat_ws(' ', m.name, s.note)`,
        authorId: 's.created_by', authorName: 'su.full_name', workspaceId: 'w.id', workspaceName: 'w.name', tag,
        version: '1', versionCount: '1', badge: `'patient_submitted'`,
        extra: `jsonb_build_object('event', 'submission', 'planId', s.plan_id, 'measurementId', s.measurement_id)`,
      })} from followup_submissions s join followup_measurements m on m.id = s.measurement_id join workspaces w on w.id = s.workspace_id join users su on su.id = s.created_by where ${subCond}`,
    ];
  },
};

/** The registry. New entry types (or spec changes) add an adapter here; nothing else in the route changes. */
export const timelineSources: TimelineSource[] = [encounterSource, documentSource, appointmentSource, noticeSource, followupSource];
export const registerTimelineSource = (s: TimelineSource) => void timelineSources.push(s);

// ---------------------------------------------------------------------------------------------------------------

const csv = (v: unknown) => (typeof v === 'string' ? v.split(',').map((s) => s.trim()).filter(Boolean) : v);
const dateStr = z.string().regex(/^\d{4}-\d{2}-\d{2}$/);
const querySchema = z.object({
  type: z.preprocess(csv, z.array(z.enum(TIMELINE_TYPES)).max(TIMELINE_TYPES.length)).optional(),
  from: dateStr.optional(),
  to: dateStr.optional(),
  source: z.union([z.enum(['own', 'shared', 'patient']), z.string().uuid()]).optional(),
  doctor: z.string().uuid().optional(),
  q: z.string().trim().max(100).optional(),
  limit: z.coerce.number().int().min(1).max(100).default(30),
  cursor: z.string().max(300).optional(),
});
type Query = z.infer<typeof querySchema>;

const cursorSchema = z.object({ t: z.string().regex(/^\d{4}-\d{2}-\d{2}T[\d:.]+Z$/), y: z.string().max(40), i: z.string().uuid() });
const encodeCursor = (ts: string, type: string, id: string) => Buffer.from(JSON.stringify({ t: ts, y: type, i: id })).toString('base64url');
function decodeCursor(c: string) {
  try {
    return cursorSchema.parse(JSON.parse(Buffer.from(c, 'base64url').toString()));
  } catch {
    throw badRequest('invalid_cursor', 'Invalid cursor');
  }
}

function formatVitals(summary: string): string {
  return summary
    .split('|')
    .map((p) => {
      const [k, v] = p.split('=');
      const def = VITAL_KINDS[k as keyof typeof VITAL_KINDS];
      return def ? `${def.label} ${v} ${def.unit}` : `${k} ${v}`;
    })
    .join(', ');
}

interface Row {
  type: string;
  id: string;
  ref_type: string;
  ts_iso: string;
  title: string;
  summary: string | null;
  author_id: string | null;
  author_name: string | null;
  workspace_id: string | null;
  workspace_name: string | null;
  tag: string;
  version: number;
  version_count: number;
  badge: string;
  extra: Record<string, unknown>;
}
interface GrantInfo {
  grantId: string;
  expiresAt: Date;
}

export function timelineRoutes(app: FastifyInstance, pool: pg.Pool) {
  const authed = { preHandler: authenticate(pool) };
  const read = workspaceGuard(pool, 'clinical.read');

  /** Runs the union query with filters and keyset pagination. */
  async function page(ctx: TimelineCtx, base: unknown[], q: Query) {
    const branches = timelineSources.flatMap((s) => s.branches(ctx));
    const params = [...base];
    const add = (v: unknown) => (params.push(v), `$${params.length}`);
    // Every positional parameter must be referenced for Postgres to infer its type, whichever sources are active.
    const where: string[] = [`($1::uuid is null or $2::uuid is null or $3::uuid is null or $4::uuid[] is null or $5::uuid[] is null or true)`];
    if (q.type?.length) where.push(`type = any(${add(q.type)}::text[])`);
    if (q.from) where.push(`ts >= ${add(q.from)}::date::timestamp at time zone 'UTC'`);
    if (q.to) where.push(`ts < (${add(q.to)}::date + 1)::timestamp at time zone 'UTC'`);
    if (q.doctor) where.push(`author_id = ${add(q.doctor)}::uuid`);
    if (q.source === 'own') where.push(`tag = 'own'`);
    else if (q.source === 'shared') where.push(`tag in ('shared', 'sent')`);
    else if (q.source === 'patient') where.push(`workspace_id is null`);
    else if (q.source) where.push(`workspace_id = ${add(q.source)}::uuid`);
    if (q.q) where.push(`search ilike ${add(`%${q.q.replace(/[\\%_]/g, '\\$&')}%`)} escape '\\'`);
    if (q.cursor) {
      const c = decodeCursor(q.cursor);
      where.push(`(ts, type, id) < (${add(c.t)}::timestamptz, ${add(c.y)}::text, ${add(c.i)}::uuid)`);
    }
    const sql = `select t.*, to_char(t.ts at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') as ts_iso
                   from (${branches.join('\n union all \n')}) t
                  where ${where.join(' and ')}
                  order by ts desc, type desc, id desc limit ${add(q.limit + 1)}`;
    const rows = (await pool.query(sql, params)).rows as Row[];
    const hasMore = rows.length > q.limit;
    const items = rows.slice(0, q.limit);
    const last = items[items.length - 1];
    return { rows: items, nextCursor: hasMore && last ? encodeCursor(last.ts_iso, last.type, last.id) : null };
  }

  const present = (r: Row, viewer: 'doctor' | 'patient', grants: Map<string, GrantInfo>) => {
    const grant = r.tag === 'shared' ? grants.get(`${r.ref_type}:${r.id}`) : undefined;
    const shared =
      r.tag === 'shared'
        ? { sharedBy: 'patient', via: 'grant', grantId: grant?.grantId ?? null, expiresAt: grant?.expiresAt ?? null, originClinic: r.workspace_name, label: r.workspace_name ? `Shared by patient · from ${r.workspace_name}` : 'Shared by patient' }
        : r.tag === 'sent'
          ? { sharedBy: 'patient', via: 'send', grantId: null, expiresAt: null, originClinic: null, label: 'Sent by patient' }
          : undefined;
    return {
      type: r.type,
      id: r.id,
      refType: r.ref_type,
      date: r.ts_iso,
      title: r.title,
      summary: r.type === 'observation' && r.summary ? formatVitals(r.summary) : (r.summary ?? ''),
      author: r.author_name ? { id: r.author_id, name: r.author_name } : null,
      source: r.workspace_id ? { kind: 'clinic', workspaceId: r.workspace_id, name: r.workspace_name } : { kind: 'patient', workspaceId: null, name: null },
      version: r.version,
      versionCount: r.version_count,
      amended: r.version_count > 1,
      // Version history is only reachable by the authoring clinic (GET /encounters/:id/versions).
      historyPath: viewer === 'doctor' && r.tag === 'own' && r.ref_type === 'encounter' && r.version_count > 1 ? `/encounters/${r.id}/versions` : null,
      verificationBadge: r.badge,
      ...(shared && { shared }),
      details: r.extra,
    };
  };

  // F07-4: doctor view for one care relationship.
  app.get('/patients/:relationshipId/timeline', read, async (req) => {
    const { relationshipId } = z.object({ relationshipId: z.string().uuid() }).parse(req.params);
    const q = querySchema.parse(req.query);
    const ws = req.workspace!;
    const rel = (await pool.query('select patient_id, status from care_relationships where id = $1 and workspace_id = $2', [relationshipId, ws.workspaceId])).rows[0];
    if (!rel) throw notFound('Patient not found');

    // Active grants to this workspace for this patient, resolved with the spec 08 scope matcher. Evaluated per request,
    // so revoked and expired grants drop out immediately. Shared content needs a live (accepted) relationship.
    const grants = new Map<string, GrantInfo>();
    const sharedEncounters: string[] = [];
    const sharedDocuments: string[] = [];
    if (rel.status === 'active') {
      const gs = (
        await pool.query(`select id, scope, expires_at from sharing_grants where patient_id = $1 and recipient_workspace_id = $2 and revoked_at is null and expires_at > now()`, [rel.patient_id, ws.workspaceId])
      ).rows as { id: string; scope: Scope; expires_at: Date }[];
      if (gs.length) {
        for (const item of await candidates(pool, rel.patient_id)) {
          for (const g of gs) {
            if (!matches(g.scope, item)) continue;
            const key = `${item.type}:${item.id}`;
            const cur = grants.get(key);
            if (!cur || cur.expiresAt < g.expires_at) grants.set(key, { grantId: g.id, expiresAt: g.expires_at });
          }
        }
        for (const key of grants.keys()) {
          const [t, id] = key.split(':') as [string, string];
          (t === 'encounter' ? sharedEncounters : sharedDocuments).push(id);
        }
      }
    }
    const ctx: TimelineCtx = { mode: 'doctor', role: ws.role, sharedEncounters, sharedDocuments };
    const out = await page(ctx, [rel.patient_id, relationshipId, ws.workspaceId, sharedEncounters, sharedDocuments], q);
    const items = out.rows.map((r) => present(r, 'doctor', grants));

    // Viewing another clinic's shared content is visible to the patient (F08-7) and audited.
    const viewed = new Map<string, { grantId: string; type: string; id: string }>();
    for (const i of items) {
      if (i.shared?.grantId && (i.refType === 'encounter' || i.refType === 'document')) viewed.set(`${i.refType}:${i.id}`, { grantId: i.shared.grantId, type: i.refType, id: i.id });
    }
    await tx(pool, async (c) => {
      for (const v of viewed.values()) {
        await c.query(`insert into shared_access_log (grant_id, patient_id, workspace_id, accessor_user_id, item_type, item_id) values ($1,$2,$3,$4,$5,$6)`, [v.grantId, rel.patient_id, ws.workspaceId, req.auth!.userId, v.type, v.id]);
      }
      await writeAudit(c, { workspaceId: ws.workspaceId, actorId: req.auth!.userId, actorRole: ws.role, action: 'timeline.viewed', targetType: 'patient', targetId: relationshipId, metadata: { entries: items.length, shared: viewed.size }, ip: req.ip });
    });
    return { items, nextCursor: out.nextCursor };
  });

  // F07-5: patient view across all doctors. Private notes and history are never selected by any adapter in this mode.
  app.get('/patient/timeline', authed, async (req) => {
    const q = querySchema.parse(req.query);
    const p = (await pool.query('select id from patients where user_id = $1', [req.auth!.userId])).rows[0];
    if (!p) return { items: [], nextCursor: null };
    const ctx: TimelineCtx = { mode: 'patient', role: 'patient', sharedEncounters: [], sharedDocuments: [] };
    const out = await page(ctx, [p.id, null, null, [], []], q);
    return { items: out.rows.map((r) => present(r, 'patient', new Map())), nextCursor: out.nextCursor };
  });
}
