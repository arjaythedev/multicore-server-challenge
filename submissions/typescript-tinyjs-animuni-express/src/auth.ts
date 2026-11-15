import { createHmac, timingSafeEqual } from "node:crypto";
import { fail } from "./http";

export type Auth = { viewer: string; token: string };
export type AuthMode = "none" | "optional" | "required";

function secret() {
  const value = process.env.JWT_SECRET;
  if (!value) throw new Error("JWT_SECRET is required");
  return value;
}

const signature = (value: string) => createHmac("sha256", secret()).update(value).digest();

export function issueToken(id: string) {
  const iat = Math.floor(Date.now() / 1000);
  const header = Buffer.from('{"alg":"HS256","typ":"JWT"}').toString("base64url");
  const payload = Buffer.from(JSON.stringify({ sub: String(id), iat, exp: iat + 30 * 86400 })).toString("base64url");
  const value = `${header}.${payload}`;
  return `${value}.${signature(value).toString("base64url")}`;
}

export function authenticate(request: Request, mode: AuthMode): Auth {
  if (mode === "none") return { viewer: "0", token: "" };
  const authorization = request.headers.get("authorization");
  if (authorization === null && mode === "optional") return { viewer: "0", token: "" };
  const match = authorization?.match(/^Token ([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)$/);
  if (!match) return fail(401, "Authentication required");
  const token = match[1];
  const [header, payload, encodedSignature] = token.split(".");
  let claims: Record<string, unknown>;
  try {
    const metadata = JSON.parse(Buffer.from(header, "base64url").toString());
    if (!metadata || metadata.alg !== "HS256" || metadata.crit !== undefined || metadata.b64 === false) {
      return fail(401, "Invalid JWT header");
    }
    const supplied = Buffer.from(encodedSignature, "base64url");
    const expected = signature(`${header}.${payload}`);
    if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) return fail(401, "Invalid signature");
    claims = JSON.parse(Buffer.from(payload, "base64url").toString());
  } catch { return fail(401, "Invalid token"); }
  const now = Date.now() / 1000;
  if (!claims || typeof claims.exp !== "number" || !Number.isFinite(claims.exp) || claims.exp <= now ||
      (claims.nbf !== undefined && (typeof claims.nbf !== "number" || !Number.isFinite(claims.nbf) || claims.nbf > now)) ||
      typeof claims.sub !== "string" || !/^[0-9]+$/.test(claims.sub)) return fail(401, "Invalid claims");
  const id = BigInt(claims.sub);
  if (id < 1n || id > 9223372036854775807n) return fail(401, "Invalid subject");
  return { viewer: id.toString(), token };
}
