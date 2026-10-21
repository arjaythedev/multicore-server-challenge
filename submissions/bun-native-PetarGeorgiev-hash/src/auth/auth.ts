import { jwtVerify } from "jose";
import { errorResponse } from "../utils/utils";
import type { AuthContext } from "../types/types";

export const jwtSecret = process.env.JWT_SECRET;
if (!jwtSecret) throw new Error("JWT_SECRET is required");

export const jwtKey = new TextEncoder().encode(jwtSecret);
const MAX_INT64 = 9223372036854775807n;

export async function authenticate(
  req: Request,
  required: boolean,
): Promise<AuthContext | Response> {
  const header = req.headers.get("authorization");

  if (header === null) {
    if (required) return errorResponse(401, "Authorization required");
    return { viewerId: 0n, token: null };
  }

  if (!header.startsWith("Token ")) {
    return errorResponse(401, "Invalid authorization");
  }

  const token = header.slice("Token ".length);
  if (!token || /\s/.test(token)) {
    return errorResponse(401, "Invalid authorization");
  }
  try {
    const { payload } = await jwtVerify(token, jwtKey, {
      algorithms: ["HS256"],
      requiredClaims: ["sub", "exp"],
    });

    if (typeof payload.sub !== "string" || !/^[1-9][0-9]*$/.test(payload.sub)) {
      return errorResponse(401, "Invalid token subject");
    }

    const viewerId = BigInt(payload.sub);
    if (viewerId > MAX_INT64) {
      return errorResponse(401, "Invalid token subject");
    }

    return { viewerId, token };
  } catch {
    return errorResponse(401, "Invalid or expired token");
  }
}
