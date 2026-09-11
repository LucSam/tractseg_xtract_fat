#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PYTHON="${PYTHON:-python3}"
SHELLCHECK="${SHELLCHECK:-shellcheck}"
for script in tractseg_xtract_fat.sh fat_simple.sh tests/verify.sh; do
  bash -n "$script"
done
"$PYTHON" -m unittest discover -s tests -v
"$SHELLCHECK" tractseg_xtract_fat.sh fat_simple.sh tests/verify.sh
"$PYTHON" -m ruff check scripts tests
"$PYTHON" -m mypy --ignore-missing-imports --cache-dir "${TMPDIR:-/tmp}/fat-mypy" scripts tests/test_workflow.py
