import { issueToken, type Auth } from "./auth";
import { withDatabase } from "./db";
import { fail, input, stringField, type Context } from "./http";
import { user } from "./models";

export async function register(request: Request) {
  const fields = await input(request, "user");
  const username = stringField(fields, "username")!;
  const email = stringField(fields, "email")!;
  const password = stringField(fields, "password")!;
  const hash = await Bun.password.hash(password, { algorithm: "bcrypt", cost: 10 });
  return withDatabase(async db => {
    const [row] = await db`INSERT INTO users (username, email, password_hash) VALUES (${username}, ${email}, ${hash})
      RETURNING id, username, email, bio, image`;
    return Response.json({ user: user(row, issueToken(row.id)) }, { status: 201 });
  });
}

export async function login(request: Request) {
  const fields = await input(request, "user");
  const email = stringField(fields, "email")!;
  const password = stringField(fields, "password")!;
  const row = await withDatabase(async db => {
    const [row] = await db`SELECT id, username, email, bio, image, password_hash FROM users WHERE email = ${email}`;
    return row;
  });
  if (!row || !await Bun.password.verify(password, row.password_hash, "bcrypt")) fail(401, "Invalid credentials");
  return Response.json({ user: user(row, issueToken(row.id)) });
}

export async function getCurrent(_request: Request, _context: Context, auth: Auth) {
  return withDatabase(async db => {
    const [row] = await db`SELECT id, username, email, bio, image FROM users WHERE id = ${auth.viewer}`;
    if (!row) fail(401, "User not found");
    return Response.json({ user: user(row, auth.token) });
  });
}

export async function updateCurrent(request: Request, _context: Context, auth: Auth) {
  const fields = await input(request, "user");
  const email = stringField(fields, "email", false);
  const username = stringField(fields, "username", false);
  const password = stringField(fields, "password", false);
  const bio = stringField(fields, "bio", false, true);
  const image = stringField(fields, "image", false, true);
  const hash = password === null ? null : await Bun.password.hash(password, { algorithm: "bcrypt", cost: 10 });
  return withDatabase(async db => {
    const [row] = await db`UPDATE users SET email = COALESCE(${email}, email), username = COALESCE(${username}, username),
      password_hash = COALESCE(${hash}, password_hash), bio = COALESCE(${bio}, bio), image = COALESCE(${image}, image)
      WHERE id = ${auth.viewer} RETURNING id, username, email, bio, image`;
    if (!row) fail(401, "User not found");
    return Response.json({ user: user(row, auth.token) });
  });
}
