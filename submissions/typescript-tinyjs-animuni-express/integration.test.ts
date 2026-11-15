// Run only on a remote runner against test/run.sh's disposable database.
import { expect, test } from "bun:test";
import { SQL } from "bun";

test("concurrent writes, shared pool, committed restart persistence, and graceful shutdown", async () => {
  const databaseUrl = process.env.DATABASE_URL;
  if (!databaseUrl || !new URL(databaseUrl).pathname.startsWith("/challenge_test_")) {
    throw new Error("This remote integration check requires test/run.sh's disposable database");
  }
  const cleanup = new SQL({ url: databaseUrl, max: 1, connectionTimeout: 5, connection: { statement_timeout: "5000" } });
  const prefix = "integration_" + crypto.randomUUID().replaceAll("-", "");
  const usernames = [prefix + "_author", prefix + "_viewer"];
  const tags = [prefix + "_a", prefix + "_b"];
  const sharedTags = [prefix + "_c", prefix + "_d"];
  let app: ReturnType<typeof Bun.spawn> | undefined;
  let base = "";

  async function start() {
    const child = Bun.spawn([process.execPath, "transport.ts"], {
      env: { ...process.env, HOST: "127.0.0.1", PORT: "0" }, stdout: "pipe", stderr: "inherit",
    });
    app = child;
    const reader = child.stdout.getReader();
    const ready = (async () => {
      let output = "";
      try {
        for (;;) {
          const chunk = await reader.read();
          if (chunk.done) throw new Error("Server exited before announcing its URL");
          output += new TextDecoder().decode(chunk.value);
          const match = output.match(/TinyJS listening on (http:\/\/127\.0\.0\.1:\d+)/);
          if (match) { base = match[1]; return; }
        }
      } finally { reader.releaseLock(); }
    })();
    let timer: ReturnType<typeof setTimeout>;
    try {
      await Promise.race([ready, new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error("Remote server startup timed out")), 10000);
      })]);
    } finally { clearTimeout(timer!); }
  }

  async function stop() {
    const child = app;
    if (!child) return;
    app = undefined;
    child.kill("SIGTERM");
    const timer = setTimeout(() => child.kill("SIGKILL"), 5000);
    try { expect(await child.exited).toBe(0); }
    finally { clearTimeout(timer); }
  }

  async function api(method: string, path: string, token = "", body?: unknown, status = 200) {
    const response = await fetch(base + path, {
      method,
      signal: AbortSignal.timeout(5000),
      headers: { ...(token ? { Authorization: `Token ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await response.text();
    if (response.status !== status) throw new Error(`${method} ${path}: expected ${status}, got ${response.status}: ${text}`);
    return text ? JSON.parse(text) : null;
  }

  try {
    await start();
    const tokens: string[] = [];
    for (const username of usernames) {
      const result = await api("POST", "/api/users", "", { user: { username, email: username + "@example.com", password: "integration-password" } }, 201);
      tokens.push(result.user.token);
    }
    const [author, viewer] = tokens;
    const created = await api("POST", "/api/articles", author, { article: { title: prefix, description: "d", body: "persisted body", tagList: tags } }, 201);
    const path = "/api/articles/" + created.article.slug;
    await Promise.all(Array.from({ length: 24 }, () => api("POST", path + "/favorite", viewer)));
    expect((await api("GET", path, viewer)).article.favoritesCount).toBe(1);
    await Promise.all(Array.from({ length: 16 }, () => api("POST", "/api/profiles/" + usernames[0] + "/follow", viewer)));
    const comments = await Promise.all(Array.from({ length: 24 }, (_, i) =>
      api("POST", path + "/comments", viewer, { comment: { body: "concurrent comment " + i } }, 201)));
    expect(new Set(comments.map(result => result.comment.id)).size).toBe(24);
    await Promise.all(Array.from({ length: 8 }, (_, i) => api("POST", "/api/articles", author, {
      article: { title: prefix + " " + i, description: "d", body: "b", tagList: i % 2 ? sharedTags : [...sharedTags].reverse() },
    }, 201)));
    const [connections] = await cleanup`SELECT count(*) FROM pg_stat_activity WHERE datname = current_database()`;
    expect(Number(connections.count)).toBeLessThanOrEqual(17); // 16 app connections plus this cleanup connection.
    await stop();
    await start();
    const persisted = (await api("GET", path, viewer)).article;
    expect(persisted.body).toBe("persisted body");
    expect(persisted.tagList).toEqual(tags);
    expect(persisted.favoritesCount).toBe(1);
    expect(persisted.favorited).toBe(true);
    expect(persisted.author.following).toBe(true);
    expect((await api("GET", path + "/comments", viewer)).comments).toHaveLength(24);
    expect((await api("GET", "/api/user", author)).user.username).toBe(usernames[0]);
    await Promise.all(Array.from({ length: 24 }, () => api("DELETE", path + "/favorite", viewer)));
    expect((await api("GET", path, viewer)).article.favoritesCount).toBe(0);
  } finally {
    try { await stop(); }
    finally {
      try {
        await cleanup`DELETE FROM users WHERE username = ANY(${cleanup.array(usernames, "TEXT")})`;
        await cleanup`DELETE FROM tags WHERE name = ANY(${cleanup.array([...tags, ...sharedTags], "TEXT")})`;
      } finally { await cleanup.close(); }
    }
  }
}, 60000);
