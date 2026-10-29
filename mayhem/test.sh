#!/usr/bin/env bash
#
# mayhem/test.sh — RUN c-ares' own GoogleTest suite (arestest, built by mayhem/build.sh). exit 0 = pass. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# arestest asserts DNS parse/encode/resolve results against mock servers on localhost. The "Live"
# tests need the public internet and are excluded (the grader re-runs this offline). The four other
# exclusions pass online but fail with no network/resolver (verified: --network none), so they cannot
# be part of an offline oracle: DefaultChannelTest.TimeoutValue (needs system resolv.conf servers) and
# SockStateDeliveryTest.* (need a default server to open a socket).
RUNNER="$SRC/build/tests/bin/arestest"
[ -x "$RUNNER" ] || { echo "missing $RUNNER — mayhem/build.sh should have built it" >&2; emit_ctrf "gtest" 0 1 0; exit 1; }

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
(cd "$(dirname "$RUNNER")" && "$RUNNER" --gtest_filter='-*Live*:DefaultChannelTest.TimeoutValue:SockStateDeliveryTest.*') > "$OUT" 2>&1
cat "$OUT" | tail -n 40

# Parse GoogleTest's own summary; a neutered/absent runner prints nothing, so there is no summary
# and the suite fails loudly rather than passing on exit status alone.
total="$(sed -nE 's/^\[==========\] ([0-9]+) tests? from .* ran\..*/\1/p' "$OUT" | tail -n1)"
passed="$(sed -nE 's/^\[  PASSED  \] ([0-9]+) tests?\./\1/p' "$OUT" | tail -n1)"
failed="$(sed -nE 's/^\[  FAILED  \] ([0-9]+) tests?, listed below:/\1/p' "$OUT" | tail -n1)"
skipped="$(sed -nE 's/^\[  SKIPPED \] ([0-9]+) tests?, listed below:/\1/p' "$OUT" | tail -n1)"
if [ -z "$total" ] || [ -z "$passed" ] || [ "$total" -lt 1000 ]; then
  echo "no plausible GoogleTest summary (total='${total:-}' passed='${passed:-}') — suite did not run" >&2
  emit_ctrf "gtest" 0 1 0; exit 1
fi
emit_ctrf "gtest" "$passed" "${failed:-0}" "${skipped:-0}"
