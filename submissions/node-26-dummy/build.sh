
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
npm ci

echo "[build] Compiling strict TypeScript..."
npm run build

echo "[build] Build completed successfully."
