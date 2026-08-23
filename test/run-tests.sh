#!/usr/bin/env bash
# Test runner. Usage:
#   test/run-tests.sh                # run every test
#   test/run-tests.sh unit           # only test/unit_test.sh
#   test/run-tests.sh -f gate        # only tests whose name matches "gate"
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER=""
declare -a FILES=()

while [ $# -gt 0 ]; do
  case "$1" in
    -f|--filter) FILTER="$2"; shift 2 ;;
    *) FILES+=("$HERE/$1_test.sh"); shift ;;
  esac
done
if [ "${#FILES[@]}" -eq 0 ]; then
  while IFS= read -r f; do FILES+=("$f"); done < <(find "$HERE" -maxdepth 1 -name '*_test.sh' | sort)
fi

TOTAL=0; PASSED=0; FAILED=0
declare -a FAILED_NAMES=()

for file in "${FILES[@]}"; do
  [ -f "$file" ] || { echo "no such test file: $file" >&2; exit 2; }
  echo ""
  echo "== $(basename "$file")"
  # discover test function names without executing them
  while IFS= read -r name; do
    [ -z "$FILTER" ] || case "$name" in *"$FILTER"*) : ;; *) continue ;; esac
    TOTAL=$(( TOTAL + 1 ))
    output="$(
      exec 2>&1
      set +e
      # shellcheck disable=SC1090
      source "$HERE/lib/harness.sh"
      setup_workspace
      default_inputs
      # shellcheck disable=SC1090
      source "$file"
      "$name"
      rc=$FAILURES
      teardown_workspace
      exit $rc
    )"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      PASSED=$(( PASSED + 1 ))
      echo "  ok   $name"
    else
      FAILED=$(( FAILED + 1 ))
      FAILED_NAMES+=("$(basename "$file"):$name")
      echo "  FAIL $name"
      [ -z "$output" ] || echo "$output"
    fi
  done < <(grep -oE '^test_[A-Za-z0-9_]+' "$file")
done

echo ""
echo "----------------------------------------"
echo "tests: $TOTAL  passed: $PASSED  failed: $FAILED"
if [ "$FAILED" -gt 0 ]; then
  printf 'failed:\n'
  printf '  %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi
exit 0
