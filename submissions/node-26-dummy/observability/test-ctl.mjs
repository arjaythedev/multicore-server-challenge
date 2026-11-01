// Execute the real ctl.sh in a disposable fixture with external commands stubbed.
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, copyFileSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const dir = mkdtempSync(join(tmpdir(), 'node26-ctl-test-'));
try {
  const obs = join(dir, 'observability'), bin = join(dir, 'bin');
  mkdirSync(obs); mkdirSync(bin); mkdirSync(join(dir, 'dist'));
  copyFileSync(new URL('./ctl.sh', import.meta.url), join(obs, 'ctl.sh'));
  writeFileSync(join(obs, 'modes.env'), 'PORT=33199\nHOST=127.0.0.1\nTRACE_RATIO=0.05\n');
  writeFileSync(join(obs, 'runtime.env'), 'BENCH_DIAGNOSTICS=1\n');
  writeFileSync(join(dir, 'dist/cluster.js'), '');
  const script = (path, body) => writeFileSync(path, '#!/usr/bin/env bash\nset -eu\n' + body, { mode: 0o700 });
  script(join(bin, 'ss'), 'exit 0\n');
  script(join(bin, 'curl'), 'exit 0\n');
  script(join(bin, 'sudo'), `if [[ "$*" == '-u postgres psql -X -A -t -d conduit_lg -c SHOW pg_stat_statements.track;' ]]; then
  echo "$TEST_SQL_TRACK"; exit 0
fi
echo "FORBIDDEN mutation" >&2; exit 99
`);
  script(join(bin, 'git'), 'if [[ "$*" == *rev-parse* ]]; then echo test-sha; fi\n');
  script(join(bin, 'node'), `if [[ "$*" == "-v" ]]; then echo v26.13.0; exit 0; fi
printf 'effective_pool=%s run=%s tracing=%s\\n' "$BENCH_DIAGNOSTICS" "$BENCH_RUN_ID" "$OTEL_SDK_DISABLED"
`);
  script(join(obs, 'sql-profile.sh'), 'printf "%s\\n" "$1" >> "$TEST_SQL_CALLS"\n');
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, TEST_SQL_CALLS: join(dir, 'sql-calls'), TEST_SQL_TRACK: 'top', BENCH_DIAGNOSTICS: '1' };
  const run = (args, success = true) => {
    const result = spawnSync('bash', [join(obs, 'ctl.sh'), ...args], { env, encoding: 'utf8' });
    assert.equal(result.status === 0, success, result.stderr);
    return result.stdout;
  };
  assert(run(['run', 'pool', 'pool-test']).includes('effective_pool=1 run=pool-test tracing=true'));
  assert(!existsSync(env.TEST_SQL_CALLS), 'pool mode must not call SQL profiling script');
  assert(readFileSync(join(obs, 'runs/pool-test/manifest.txt'), 'utf8').includes('sql_mode=preserve'));
  assert(readFileSync(join(obs, 'runs/pool-test/manifest.txt'), 'utf8').includes('pg_stat_statements_track=top'));
  assert(readFileSync(join(obs, 'runs/pool-test/manifest.txt'), 'utf8').includes(`pool_diagnostics_dir=${obs}/runs/pool-test/pool`));
  assert(readFileSync(join(obs, 'runs/pool-test/manifest.txt'), 'utf8').includes('pool_file_max_bytes=10485760'));
  env.TEST_SQL_TRACK = 'none';
  run(['run', 'pool', 'pool-none']);
  assert(readFileSync(join(obs, 'runs/pool-none/manifest.txt'), 'utf8').includes('pg_stat_statements_track=none'));
  env.TEST_SQL_TRACK = 'broken'; run(['run', 'pool', 'bad-track'], false);
  env.TEST_SQL_TRACK = 'top';
  assert(run(['run', 'baseline', 'baseline-test']).includes('effective_pool=0'));
  assert(run(['run', 'trace5', 'trace-test', '--pool']).includes('effective_pool=1 run=trace-test tracing=false'));
  assert(readFileSync(join(obs, 'runs/trace-test/manifest.txt'), 'utf8').includes('pool_diagnostics=1'));
  assert.equal(readFileSync(env.TEST_SQL_CALLS, 'utf8'), 'off\non\n');
  run(['run', 'pool', 'invalid-option', '--bad'], false);
  run(['run', 'pool', '../bad'], false);
  run(['run', 'pool', 'pool-test'], false);
  env.BENCH_DIAGNOSTICS_MAX_BYTES = '0'; run(['run', 'pool', 'bad-size'], false);
  console.log('PASS ctl: pool preserves SQL settings; explicit off; trace5 --pool; manifest; validation; no real sudo/services');
} finally { rmSync(dir, { recursive: true, force: true }); }
