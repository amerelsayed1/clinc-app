import type pg from 'pg';

/** Creates an empty draft encounter (version 1). Used by the API and by "start consultation". */
export async function createDraftEncounter(
  c: pg.PoolClient,
  i: { workspaceId: string; relationshipId: string; appointmentId?: string | null; authorId: string },
): Promise<string> {
  const e = (
    await c.query(`insert into encounters (workspace_id, care_relationship_id, appointment_id, author_id) values ($1,$2,$3,$4) returning id`, [
      i.workspaceId,
      i.relationshipId,
      i.appointmentId ?? null,
      i.authorId,
    ])
  ).rows[0];
  await c.query(`insert into encounter_versions (encounter_id, version, author_id) values ($1, 1, $2)`, [e.id, i.authorId]);
  return e.id as string;
}
