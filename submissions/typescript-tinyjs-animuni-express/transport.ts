import { createApplication } from "./.tinyjs/server/server.mjs";
import { closeDatabase, verifyDatabase } from "./src/db";
import { errorResponse } from "./src/http";

if (!process.env.JWT_SECRET) throw new Error("JWT_SECRET is required");
await verifyDatabase();
const handle = createApplication({ scripts: [], styles: [] });
const server = Bun.serve({
  hostname: process.env.HOST ?? "0.0.0.0",
  port: Number(process.env.PORT ?? 80),
  development: false,
  idleTimeout: 120,
  fetch(request) { return handle(request); },
  error(error) {
    console.error("HTTP handler failed", error.name);
    return errorResponse(500, "Internal server error");
  },
});
console.log(`TinyJS listening on ${server.url.origin}`);
let stopping = false;
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.once(signal, async () => {
    if (stopping) return;
    stopping = true;
    try {
      await server.stop();
      await closeDatabase();
    } catch (error) {
      console.error("Shutdown failed", error instanceof Error ? error.name : "UnknownError");
      process.exitCode = 1;
    }
  });
}
