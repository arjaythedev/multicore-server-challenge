#!/usr/bin/env bash
# Fetch the other submissions exactly as they were pinned in rivals.tsv, and build them with their own build scripts.
#
#   usage: fetch_rivals.sh PATH_TO_CLONE_OF_arjaythedev/multicore-server-challenge WORKDIR
#   env:   DOTNET10 (directory of a .NET 10 SDK, needed by p22 only)
#
# Nothing is run here except each submission's own build.sh (toolchains: rust, go, gcc + liburing + libpq, zig 0.17, .NET 10).
# Rivals are built with the toolchains installed on this machine, not with their install.sh scripts.
set -euo pipefail
repo=$1; work=$2
mkdir -p "$work"
grep -v '^#' "$(dirname "$0")/rivals.tsv" | while IFS=$'\t' read -r label pr author dir sha build extra; do
  [ -n "$label" ] || continue
  git -C "$repo" fetch -q origin "pull/$pr/head:refs/prs/$pr"
  got=$(git -C "$repo" rev-parse "refs/prs/$pr")
  case "$got" in "$sha"*) ;; *) echo "PR $pr moved: head is now ${got:0:12}, the measurements used $sha" >&2 ;; esac
  rm -rf "$work/$label"; mkdir -p "$work/$label"
  git -C "$repo" archive "refs/prs/$pr" "submissions/$dir" | tar -x -C "$work/$label" --strip-components=2
  echo "== building $label (PR $pr, $author)"
  (cd "$work/$label" && eval "$build") > "$work/$label.build.log" 2>&1 && echo ok || { echo "FAILED, see $work/$label.build.log"; true; }
done
