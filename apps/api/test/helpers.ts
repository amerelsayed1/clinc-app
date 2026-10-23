import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { buildApp } from '../src/app.js';
import { createPool } from '../src/db.js';
import { TEST_DB_URL } from './global-setup.js';

export async function setupApp() {
  const pool = createPool(TEST_DB_URL);
  const sent: { phone: string; text: string }[] = [];
  const app = await buildApp(pool, { sms: { send: async (phone, text) => void sent.push({ phone, text }) } });
  return { app, pool, sent };
}

export async function reset(pool: pg.Pool) {
  await pool.query('truncate audit_log, document_access, document_reviews, document_shares, document_pages, documents, observations, encounter_versions, encounters, appointments, care_relationships, patients, invitations, memberships, workspaces, doctor_profiles, sessions, otp_codes, users restart identity cascade');
}

export interface Session {
  accessToken: string;
  refreshToken: string;
  user: { id: string };
  headers: { authorization: string };
}

export async function login(app: FastifyInstance, phone: string): Promise<Session> {
  const req = await app.inject({ method: 'POST', url: '/auth/otp/request', payload: { phone } });
  const { devCode } = req.json();
  const res = await app.inject({ method: 'POST', url: '/auth/otp/verify', payload: { phone, code: devCode } });
  const body = res.json();
  return { ...body, headers: { authorization: `Bearer ${body.accessToken}` } };
}

export async function makeVerifiedDoctor(app: FastifyInstance, pool: pg.Pool, phone: string, verify = true) {
  const s = await login(app, phone);
  await app.inject({ method: 'POST', url: '/doctors/register', headers: s.headers, payload: { fullName: 'Dr Test', licenseNumber: 'LIC-123' } });
  if (verify) await pool.query(`update doctor_profiles set verification_status = 'verified' where user_id = $1`, [s.user.id]);
  const ws = await app.inject({ method: 'POST', url: '/workspaces', headers: s.headers, payload: { name: 'Test Clinic' } });
  return { ...s, workspaceId: ws.json().id as string };
}
