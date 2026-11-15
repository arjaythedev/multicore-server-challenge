import { SQL } from "bun";

// TinyJS bundles routes; the transport also imports this file for startup and shutdown.
const state = globalThis as typeof globalThis & { conduitDatabase?: SQL };

function database() {
  if (!state.conduitDatabase) {
    const url = process.env.DATABASE_URL;
    if (!url || !/^postgres(?:ql)?:\/\//.test(url)) throw new Error("A PostgreSQL DATABASE_URL is required");
    state.conduitDatabase = new SQL({
      url,
      max: 16,
      idleTimeout: 0,
      maxLifetime: 0,
      connectionTimeout: 5,
      prepare: true,
    });
  }
  return state.conduitDatabase;
}

export type Connection = Awaited<ReturnType<SQL["reserve"]>>;

export async function withDatabase<T>(run: (db: Connection) => Promise<T>): Promise<T> {
  const db = await database().reserve({ signal: AbortSignal.timeout(5000) });
  try { return await run(db); }
  finally { db.release(); }
}

export async function verifyDatabase() {
  await withDatabase(async db => {
    const [row] = await db`SHOW server_version_num`;
    const version = Number(row.server_version_num);
    if (version < 180000 || version >= 190000) throw new Error("PostgreSQL 18 is required");
  });
}

export async function closeDatabase() {
  await state.conduitDatabase?.close();
}
