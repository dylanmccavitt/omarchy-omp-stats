#!/usr/bin/env bash
set -euo pipefail

plugin_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
bridge="$plugin_dir/bin/stats-json"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fake_omp="$tmp_dir/omp binary"
cat >"$fake_omp" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} == stats && ${2:-} == --json ]]
printf '%s\n' 'Syncing session files...'
printf '%s\n' '{"overall":{"totalRequests":2},"byModel":[]}'
FAKE
chmod +x "$fake_omp"

output="$(OMP_BIN="$fake_omp" bash "$bridge")"
printf '%s' "$output" | node -e '
  const fs = require("node:fs")
  const value = JSON.parse(fs.readFileSync(0, "utf8"))
  if (value.overall.totalRequests !== 2) process.exit(1)
'

missing_error="$tmp_dir/missing-error"
if OMP_BIN="$tmp_dir/does-not-exist" bash "$bridge" >"$tmp_dir/missing-output" 2>"$missing_error"; then
  printf '%s\n' 'expected an invalid OMP_BIN to fail' >&2
  exit 1
fi

if [[ $(<"$missing_error") != *"requires the omp CLI"* ]]; then
  printf '%s\n' 'missing-OMP error was not actionable' >&2
  exit 1
fi

printf '%s\n' 'OMP Stats bridge tests passed'
