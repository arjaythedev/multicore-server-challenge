import { SignJWT } from "jose";
import { jwtKey } from "../auth/auth";

export const res = (body: any, status: number) => {
  return new Response(JSON.stringify(body), {
    headers: { "Content-Type": "application/json" },
    status: status,
  });
};

export function errorResponse(status: number, message: string): Response {
  return Response.json({ errors: { body: [message] } }, { status });
}

export function issueToken(userId: string | number | bigint): Promise<string> {
  return new SignJWT({})
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(String(userId))
    .setIssuedAt()
    .setExpirationTime("30d")
    .sign(jwtKey);
}

export const hashPasswod = async (password: string): Promise<string> => {
  return Bun.password.hash(password, {
    algorithm: "bcrypt",
    cost: 10,
  });
};

export const getLimitAndOffset = (params: URLSearchParams) => {
  const rawLimit = params.get("limit");
  const limit = rawLimit === null ? 20 : Number(rawLimit);
  if (
    rawLimit !== null &&
    (!/^[0-9]+$/.test(rawLimit) ||
      !Number.isInteger(limit) ||
      limit < 1 ||
      limit > 100)
  ) {
    return errorResponse(422, "Invalid limit");
  }
  if (limit < 1 || limit > 100) {
    return errorResponse(422, "Invalid limit");
  }

  const rawOffset = params.get("offset");
  let offset = 0n;
  if (rawOffset !== null) {
    if (!/^[0-9]+$/.test(rawOffset)) {
      return errorResponse(422, "Invalid offset");
    }
    offset = BigInt(rawOffset);
    if (offset > 9223372036854775807n) {
      return errorResponse(422, "Invalid offset");
    }
  }
  return { limit, offset };
};

export class BadBody extends Error {}

type Obj = Record<string, unknown>;

const isObj = (x: unknown): x is Obj =>
  typeof x === "object" && x !== null && !Array.isArray(x);

export async function readWrapper(req: Request, key: string): Promise<Obj> {
  let top: unknown;
  try {
    top = await req.json();
  } catch {
    throw new BadBody();
  }
  if (!isObj(top)) throw new BadBody();
  const inner = top[key];
  if (!isObj(inner)) throw new BadBody();
  return inner;
}

export function optString(m: Obj, k: string, nonEmpty = false): string | null {
  const v = m[k];
  if (v === undefined || v === null) return null;
  if (typeof v !== "string") throw new BadBody();
  if (nonEmpty && v === "") throw new BadBody();
  return v;
}

export function reqString(m: Obj, k: string): string {
  const v = optString(m, k, true);
  if (v === null) throw new BadBody();
  return v;
}
