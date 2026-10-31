# Node.js 26 + TypeScript 7 dummy app

A tiny clustered HTTP server for testing the submissions layout. It uses
TypeScript 7.0.2 with strict type checking and Node.js 26 type definitions.

## Run

Node.js 26 and npm are required.

```bash
bash build.sh
HOST=127.0.0.1 PORT=3000 bash start.sh
```

`build.sh` installs the locked development dependencies and compiles `src/`
into `dist/`. The start script defaults to `0.0.0.0:3110`.

The router covers all 19 operations required by `SPEC.md`. The tag endpoint
returns an empty health response; the other handlers are named placeholders in
`src/handlers.ts` and return 501 until implemented.

Front: direct
