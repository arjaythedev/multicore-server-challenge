
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

echo "[build] Checking Node.js version..."

node -e '
  const major = Number(process.versions.node.split(".")[0]);

  if (major !== 26) {
    console.error(
      `Expected Node.js 26, got ${process.version}`
    );
    process.exit(1);
  }
'

echo "[build] Installing locked dependencies..."
npm ci --include=dev

echo "[build] Building bcrypt from source..."
npm_config_build_from_source=true npm rebuild bcrypt

echo "[build] Compiling strict TypeScript..."
node --input-type=module -e 'import { rmSync } from "node:fs"; rmSync(new URL("./dist/", import.meta.url), { recursive: true, force: true });'
npm run build

echo "[build] Build completed successfully."
