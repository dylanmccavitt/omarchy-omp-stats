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

failing_omp="$tmp_dir/failing omp"
cat >"$failing_omp" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} == stats && ${2:-} == --json ]]
printf '%s\n' 'Provider sync failed' >&2
exit 42
FAKE
chmod +x "$failing_omp"

failing_error="$tmp_dir/failing-error"
if OMP_BIN="$failing_omp" bash "$bridge" >"$tmp_dir/failing-output" 2>"$failing_error"; then
  printf '%s\n' 'expected a nonzero OMP exit to fail' >&2
  exit 1
else
  failing_status=$?
fi

[[ $failing_status -eq 42 ]] || {
  printf 'expected bridge exit 42, got %d\n' "$failing_status" >&2
  exit 1
}
[[ $(<"$failing_error") == *"Provider sync failed"* ]] || {
  printf '%s\n' 'OMP diagnostic was not preserved' >&2
  exit 1
}
[[ $(<"$failing_error") == *"exit 42"* ]] || {
  printf '%s\n' 'bridge did not report the OMP exit status' >&2
  exit 1
}

timeout_bin="$tmp_dir/timeout-bin"
mkdir -p "$timeout_bin"
cat >"$timeout_bin/timeout" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} == --kill-after=5s && ${2:-} == 115s ]]
shift 2
exec /usr/bin/timeout --kill-after=1s 0.1s "$@"
FAKE
chmod +x "$timeout_bin/timeout"

hanging_omp="$tmp_dir/hanging omp"
cat >"$hanging_omp" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} == stats && ${2:-} == --json ]]
trap 'printf "%s\n" terminated >"$OMP_TIMEOUT_MARKER"; exit 0' TERM
while true; do sleep 1; done
FAKE
chmod +x "$hanging_omp"

timeout_marker="$tmp_dir/timeout-marker"
timeout_error="$tmp_dir/timeout-error"
if PATH="$timeout_bin:$PATH" OMP_TIMEOUT_MARKER="$timeout_marker" OMP_BIN="$hanging_omp" \
    bash "$bridge" >"$tmp_dir/timeout-output" 2>"$timeout_error"; then
  printf '%s\n' 'expected a stalled OMP process to time out' >&2
  exit 1
else
  timeout_status=$?
fi

[[ $timeout_status -eq 124 ]] || {
  printf 'expected bridge exit 124, got %d\n' "$timeout_status" >&2
  exit 1
}
[[ $(<"$timeout_marker") == "terminated" ]] || {
  printf '%s\n' 'timeout did not terminate the OMP child' >&2
  exit 1
}
[[ $(<"$timeout_error") == *"refresh timed out"* ]] || {
  printf '%s\n' 'timeout error was not actionable' >&2
  exit 1
}

no_json_omp="$tmp_dir/no-json omp"
cat >"$no_json_omp" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} == stats && ${2:-} == --json ]]
printf '%s\n' 'Sync completed without a report'
FAKE
chmod +x "$no_json_omp"

no_json_error="$tmp_dir/no-json-error"
if OMP_BIN="$no_json_omp" bash "$bridge" >"$tmp_dir/no-json-output" 2>"$no_json_error"; then
  printf '%s\n' 'expected output without JSON to fail' >&2
  exit 1
else
  no_json_status=$?
fi

[[ $no_json_status -eq 65 ]] || {
  printf 'expected bridge exit 65, got %d\n' "$no_json_status" >&2
  exit 1
}
[[ $(<"$no_json_error") == *"received no JSON object"* ]] || {
  printf '%s\n' 'no-JSON error was not actionable' >&2
  exit 1
}

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
