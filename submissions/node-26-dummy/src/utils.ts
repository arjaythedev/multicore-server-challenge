import type { IncomingMessage, ServerResponse } from 'node:http';
import { Pool, type PoolClient } from 'pg';
import bcrypt from 'bcrypt';
import { SignJWT, jwtVerify } from 'jose';

export interface RequestContext {
  readonly request: IncomingMessage;
  readonly response: ServerResponse;
  readonly url: URL;
  readonly params: Readonly<Record<string, string>>;
}
export type Handler = (context: RequestContext) => void | Promise<void>;
export class HttpError extends Error {
  constructor(readonly status: number, message: string) { super(message); }
}
const databaseUrl = process.env.DATABASE_URL;
const secret = process.env.JWT_SECRET;
if (!databaseUrl || !secret) throw new Error('DATABASE_URL and JWT_SECRET are required');
const poolSize = Number(process.env.PG_POOL_SIZE);
if (!Number.isInteger(poolSize) || poolSize < 1 || poolSize > 10) {
  throw new Error('Start through cluster.js: invalid PG_POOL_SIZE');
}
const key = new TextEncoder().encode(secret);
export const pool = new Pool({ connectionString: databaseUrl, max: poolSize,
  connectionTimeoutMillis: 10_000, application_name: 'node-26-conduit' });
pool.on('error', (error: Error) => { console.error('Idle database connection error', error); });

// Nothing is installed or measured when diagnostics are disabled.
export let finishPoolDiagnostics: (() => Promise<void>) | undefined;
if (process.env.BENCH_DIAGNOSTICS === '1') {
  const { instrumentPool } = await import('./pool-diagnostics.js');
  finishPoolDiagnostics = await instrumentPool(pool);
}

export async function transaction<T>(work: (client: PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  let broken = false;
  try {
    await client.query('BEGIN');
    const result = await work(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    try { await client.query('ROLLBACK'); } catch { broken = true; }
    throw error;
  } finally {
    client.release(broken);
  }
}

export function sendJson(response: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  if (payload === undefined) throw new Error('Response is not JSON');
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload) });
  response.end(payload);
}
export function sendError(response: ServerResponse, status: number, message: string): void {
  sendJson(response, status, { errors: { body: [message] } });
}
export function fail(status: number, message: string): never { throw new HttpError(status, message); }
export function first<T>(rows: T[], status = 404): T { return rows[0] ?? fail(status, 'Not found'); }
export function object(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) fail(422, 'Expected object');
  return value as Record<string, unknown>;
}
export async function readBody(request: IncomingMessage, wrapper: string): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let size = 0;
  // Do not destroy the socket on an oversized body: send a proper HTTP error.
  for await (const chunk of request.iterator({ destroyOnReturn: false })) {
    const buffer: Buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk as string);
    size += buffer.length;
    if (size > 1024 * 1024) { request.resume(); fail(413, 'Body too large'); }
    chunks.push(buffer);
  }
  let parsed: unknown;
  try { parsed = JSON.parse(Buffer.concat(chunks).toString('utf8')) as unknown; }
  catch { fail(422, 'Invalid JSON'); }
  return object(object(parsed)[wrapper]);
}
export function string(value: unknown, empty = false): string {
  if (typeof value !== 'string' || (!empty && value.length === 0) || value.includes('\0')) fail(422, 'Invalid string');
  return value;
}
export function optional(value: unknown, empty = false): string | null {
  return value == null ? null : string(value, empty);
}
export async function passwordHash(value: string): Promise<string> {
  if (Buffer.byteLength(value) > 72) fail(422, 'Password exceeds 72 bytes');
  return bcrypt.hash(value, 10);
}
export async function passwordMatches(value: string, hash: string): Promise<boolean> {
  return Buffer.byteLength(value) <= 72 && bcrypt.compare(value, hash);
}
export function validId(value: unknown): value is string {
  return typeof value === 'string' && /^\d+$/.test(value) && value.replace(/^0+/, '').length <= 19 &&
    BigInt(value) > 0n && BigInt(value) <= 9223372036854775807n;
}
export interface UserRow { id: string; username: string; email: string; bio: string | null; image: string | null }
async function verifyAuthorization(request: IncomingMessage, required: boolean): Promise<{ id: string; token: string }> {
  const header = request.headers.authorization;
  if (header === undefined && !required) return { id: '0', token: '' };
  if (!header || !/^Token \S+$/.test(header)) fail(401, 'Invalid authorization');
  const token = header.slice(6);
  let id: string;
  try {
    const { payload } = await jwtVerify(token, key, { algorithms: ['HS256'], requiredClaims: ['sub', 'exp'] });
    if (!validId(payload.sub)) fail(401, 'Invalid subject');
    id = BigInt(payload.sub).toString();
  } catch { fail(401, 'Invalid token'); }
  return { id, token };
}
export async function authenticate(request: IncomingMessage, required = true): Promise<{ id: string; token: string }> {
  const auth = await verifyAuthorization(request, required);
  if (auth.id === '0') return auth;
  const result = await pool.query<{ id: string }>('SELECT id FROM users WHERE id=$1', [auth.id]);
  first(result.rows, 401);
  return auth;
}
export async function authenticateUser(request: IncomingMessage): Promise<{ row: UserRow; token: string }> {
  const { id, token } = await verifyAuthorization(request, true);
  const row = first((await pool.query<UserRow>('SELECT id,username,email,bio,image FROM users WHERE id=$1', [id])).rows, 401);
  return { row, token };
}
export function issueToken(id: string): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ sub: id, iat: now, exp: now + 30 * 86400 })
    .setProtectedHeader({ alg: 'HS256' }).sign(key);
}
export function safeInteger(value: string | number): number {
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < 0) throw new Error('Unsafe JSON integer');
  return number;
}
export function pagination(url: URL): { limit: number; offset: number } {
  const parse = (name: string, fallback: number, min: number, max: number): number => {
    const raw = url.searchParams.get(name);
    if (raw === null) return fallback;
    const n = Number(raw);
    if (!/^\d+$/.test(raw) || !Number.isSafeInteger(n) || n < min || n > max) fail(422, `Invalid ${name}`);
    return n;
  };
  return { limit: parse('limit', 20, 1, 100), offset: parse('offset', 0, 0, 2147483647) };
}
