import { expect, test } from "bun:test";
import { createHmac } from "node:crypto";
import { authenticate, issueToken } from "./auth";
import { endpoint } from "./endpoint";
import { commentId, HttpError, input, pagination, stringField } from "./http";
import { article, comment } from "./models";

process.env.JWT_SECRET = "unit-test-secret";
const request = (header?: string) => new Request("http://localhost/api/user", {
  headers: header === undefined ? {} : { authorization: header },
});
function token(claims: unknown, alg = "HS256", secret = process.env.JWT_SECRET!) {
  const value = Buffer.from(JSON.stringify({ alg })).toString("base64url") + "." +
    Buffer.from(JSON.stringify(claims)).toString("base64url");
  return value + "." + createHmac("sha256", secret).update(value).digest("base64url");
}

test("HS256 issuance and per-request verification, expiration, algorithms, and bigint subjects", () => {
  const issued = issueToken("9223372036854775807");
  expect(authenticate(request(`Token ${issued}`), "required").viewer).toBe("9223372036854775807");
  const claims = JSON.parse(Buffer.from(issued.split(".")[1], "base64url").toString());
  expect(Object.keys(claims).sort()).toEqual(["exp", "iat", "sub"]);
  expect(claims.exp - claims.iat).toBe(30 * 86400);
  const valid = { sub: "1", exp: Date.now() / 1000 + 3600 };
  for (const bad of [
    "garbage", `Bearer ${issued}`, `Token ${token(valid, "HS512")}`, `Token ${token(valid, "none")}`,
    `Token ${token(valid, "HS256", "wrong")}`, `Token ${token({ ...valid, exp: 0 })}`,
    `Token ${token({ sub: "1" })}`, `Token ${token({ ...valid, sub: 1 })}`,
    `Token ${token({ ...valid, sub: "0" })}`, `Token ${token({ ...valid, sub: "9223372036854775808" })}`,
    `Token ${token({ ...valid, nbf: valid.exp })}`,
  ]) expect(() => authenticate(request(bad), "optional")).toThrow(HttpError);
  expect(() => authenticate(request(), "required")).toThrow(HttpError);
  expect(authenticate(request(), "optional").viewer).toBe("0");
  expect(authenticate(request("garbage"), "none").viewer).toBe("0");
  process.env.JWT_SECRET = "changed";
  expect(() => authenticate(request(`Token ${issued}`), "required")).toThrow(HttpError);
  process.env.JWT_SECRET = "unit-test-secret";
});

test("integer pagination accepts leading zeros and rejects coercion and overflow", () => {
  expect(pagination(new URL("http://localhost/?limit=05&offset=005"))).toEqual({ limit: "5", offset: "5" });
  expect(pagination(new URL("http://localhost/"))).toEqual({ limit: "20", offset: "0" });
  for (const query of ["limit=", "limit=0", "limit=101", "limit=1.5", "limit=%2B5", "limit=%205",
    "offset=-1", "offset=abc", "offset=", "offset=9223372036854775808"]) {
    expect(() => pagination(new URL("http://localhost/?" + query))).toThrow(HttpError);
  }
  expect(commentId("005")).toBe("5");
  for (const id of ["1.5", "-1", "0", "abc", "9223372036854775808"]) expect(() => commentId(id)).toThrow(HttpError);
});

test("request wrappers, null updates, UTF-8 password limit, and bcrypt cost 10", async () => {
  for (const body of ["", "{", "null", "[]", '{"user":[]}', '{"user":null}', '{"user":7}']) {
    await expect(input(new Request("http://localhost", { method: "POST", body }), "user")).rejects.toThrow(HttpError);
  }
  expect(stringField({ bio: null }, "bio", false, true)).toBeNull();
  expect(stringField({ bio: "" }, "bio", false, true)).toBe("");
  expect(() => stringField({ email: "" }, "email", false)).toThrow(HttpError);
  expect(() => stringField({ bio: 5 }, "bio", false, true)).toThrow(HttpError);
  expect(() => stringField({ password: "é".repeat(37) }, "password")).toThrow(HttpError);
  const password = stringField({ password: "é".repeat(36) }, "password")!;
  const hash = await Bun.password.hash(password, { algorithm: "bcrypt", cost: 10 });
  expect(hash).toMatch(/^\$2[aby]\$10\$/);
  expect(await Bun.password.verify(password, hash, "bcrypt")).toBe(true);
  expect(await Bun.password.verify("wrong", hash, "bcrypt")).toBe(false);
});

test("serializers preserve nulls, UTC milliseconds, integer counts, and list body omission", () => {
  const row = { id: "7", slug: "test-7", title: "Test", description: "Description", body: "Body", tag_list: ["a"],
    created_at: new Date("2025-01-01T12:00:00.123Z"), updated_at: new Date("2025-01-01T12:00:00.123Z"),
    username: "author", bio: null, image: null, following: false, favorited: true, favorites_count: "3" };
  expect(article(row).favoritesCount).toBe(3);
  expect(article(row).author.bio).toBeNull();
  expect(article(row).createdAt).toBe("2025-01-01T12:00:00.123Z");
  expect(article({ ...row, body: undefined })).not.toHaveProperty("body");
  expect(comment(row).id).toBe(7);
});

test("errors use the Conduit shape and auth runs before body handling", async () => {
  let called = false;
  const handler = endpoint("required", async () => { called = true; throw new Error("must not run"); });
  const response = await handler(request(), { params: {} });
  expect(response.status).toBe(401);
  expect(await response.json()).toEqual({ errors: { body: ["Authentication required"] } });
  expect(called).toBe(false);
});
