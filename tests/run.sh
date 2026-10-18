#!/usr/bin/env bash
# Both suites, in one command, with the same invocations the pipeline uses.
#
# Two runners because there are two languages, and neither is a wrapper around
# the other: the scenario library is plain modules executed by the generator's
# own runtime, and the baseline tools are standalone scripts. What they share
# is that neither suite needs anything installed to run - the generator's
# built-in modules are substituted by a resolver hook, and the Python suite
# uses the standard library's runner.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ "${1:-all}" != "python" ]; then
  echo "== scenario library =="
  node --import ./tests/scenarios/support/register.mjs --test 'tests/scenarios/*.test.mjs'
fi

if [ "${1:-all}" != "node" ]; then
  echo "== baseline tools =="
  PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
    --start-directory tests/baseline --top-level-directory tests/baseline --verbose
fi
