#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
python3 "$ROOT/tests/fixtures/action_sandbox_probe.py" "$ROOT/sml/action_sandbox.py"
