export class HttpError extends Error {
  constructor(readonly status: number, message: string) { super(message); }
}

export function fail(status: number, message: string): never {
  throw new HttpError(status, message);
}

export const errorResponse = (status: number, message: string) =>
  Response.json({ errors: { body: [message] } }, { status });

export type Fields = Record<string, unknown>;
export type Context = { params: Record<string, string> };

export async function input(request: Request, key: string): Promise<Fields> {
  let value: unknown;
  try { value = await request.json(); }
  catch { return fail(422, "Malformed JSON"); }
  if (!value || typeof value !== "object" || Array.isArray(value)) fail(422, "Expected an object");
  const fields = (value as Fields)[key];
  if (!fields || typeof fields !== "object" || Array.isArray(fields)) fail(422, `Expected ${key} object`);
  return fields as Fields;
}

export function stringField(fields: Fields, name: string, required = true, allowEmpty = false): string | null {
  const value = fields[name];
  if (!required && value == null) return null;
  if (typeof value !== "string" || (!allowEmpty && !value.length) || value.includes("\0")) {
    fail(422, `Invalid ${name}`);
  }
  if (name === "password" && Buffer.byteLength(value) > 72) fail(422, "Password exceeds 72 bytes");
  return value;
}

export function pagination(url: URL) {
  function integer(name: string, fallback: string, min: bigint, max: bigint) {
    const value = url.searchParams.get(name) ?? fallback;
    if (!/^[0-9]+$/.test(value)) fail(422, `Invalid ${name}`);
    const number = BigInt(value);
    if (number < min || number > max) fail(422, `Invalid ${name}`);
    return number.toString();
  }
  return { limit: integer("limit", "20", 1n, 100n), offset: integer("offset", "0", 0n, 9223372036854775807n) };
}

export function commentId(value: string) {
  if (!/^[0-9]+$/.test(value)) fail(404, "Comment not found");
  const id = BigInt(value);
  if (id < 1n || id > 9223372036854775807n) fail(404, "Comment not found");
  return id.toString();
}
