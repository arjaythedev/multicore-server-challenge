#!/usr/bin/env bash
# bash Benchmarks/compare.sh before after   -> time and allocation per benchmark, and how much each changed
cd "$(dirname "$0")" && exec python3 compare.py "$@"
