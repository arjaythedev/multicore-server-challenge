#!/usr/bin/env bash
# Installs the production dependencies and builds the production container. Run it again after any change.
# Leaves tools/ (the test and analysis tools, a separate project) alone.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

composer install --no-dev --optimize-autoloader --no-interaction --no-progress

# The compiled container is never rebuilt while the server runs, so start from an empty cache.
php bin/console cache:clear --env=prod --no-debug --no-warmup
php bin/console cache:warmup --env=prod --no-debug
echo "built vendor/ and var/cache/prod"
