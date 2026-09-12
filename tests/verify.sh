#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PYTHON="${PYTHON:-python3}"
SHELLCHECK="${SHELLCHECK:-shellcheck}"
for script in fat.sh tests/verify.sh; do bash -n "$script"; done
"$PYTHON" -m unittest discover -s tests -v
"$SHELLCHECK" fat.sh tests/verify.sh
FAT_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fat-check.XXXXXX")"
trap 'rm -rf "$FAT_CHECK_DIR"' EXIT
"$PYTHON" - "$FAT_CHECK_DIR/fat_qc.py" <<'PY'
from pathlib import Path
import sys
source = Path('fat.sh').read_text().split("<<'FAT_QC_PY'\n", 1)[1].split("\nFAT_QC_PY\n", 1)[0]
Path(sys.argv[1]).write_text(source + '\n')
PY
"$PYTHON" -m ruff check scripts tests "$FAT_CHECK_DIR/fat_qc.py"
"$PYTHON" -m mypy --ignore-missing-imports --cache-dir "${TMPDIR:-/tmp}/fat-mypy" scripts tests "$FAT_CHECK_DIR/fat_qc.py"
