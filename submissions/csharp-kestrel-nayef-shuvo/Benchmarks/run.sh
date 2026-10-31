#!/usr/bin/env bash
# Runs the BenchmarkDotNet benchmarks and saves the results under Benchmarks/results/<label>/ for compare.sh.
#   bash Benchmarks/run.sh before                      # Http, Auth and bcrypt benchmarks (about 6 minutes)
#   bash Benchmarks/run.sh after '*HttpBenchmarks*'    # only the benchmarks matching the filter
#   bash Benchmarks/run.sh q1 '*QueryBenchmarks*'      # the SQL ones: needs the database from the README
#   bash Benchmarks/run.sh quick '*Http*' --job short  # extra arguments go to BenchmarkDotNet (fewer, noisier runs)
#   bash Benchmarks/run.sh --list                      # list every benchmark
#   bash Benchmarks/run.sh --check                     # check our bcrypt against libcrypt and BCrypt.Net-Next
# The SQL benchmarks are left out of a run without a filter, because they need a database.
set -euo pipefail
cd "$(dirname "$0")"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
if [ "${1:-}" = --list ]; then exec dotnet run -c Release -- --list flat; fi
if [ "${1:-}" = --check ]; then exec dotnet run -c Release -- --check; fi
LABEL="${1:?usage: run.sh <label> [filter] [BenchmarkDotNet args]}"; shift
if [ $# -gt 0 ] && [[ "$1" != --* ]]; then FILTERS=("$1"); shift; else FILTERS=('*HttpBenchmarks*' '*AuthBenchmarks*' '*BcryptBenchmarks*'); fi
OUT="results/$LABEL"
rm -rf "$OUT"; mkdir -p "$OUT"
# --inprocess: no separate build per benchmark; the code is the one in this build, on this CPU.
dotnet run -c Release -- --inprocess --exporters json markdown --artifacts "$OUT" --filter "${FILTERS[@]}" "$@"
echo; echo "saved to Benchmarks/$OUT   (compare two runs with: bash Benchmarks/compare.sh <label-a> <label-b>)"
