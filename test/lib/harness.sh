#!/usr/bin/env bash
# Minimal dependency-free test harness for entrypoint.sh.
#
# Test files define functions named test_*; run-tests.sh discovers and runs
# each one in its own subshell with a fresh temp workspace. No network is
# used: curl and sleep are replaced by the stubs in test/stubs.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$ROOT_DIR/.." && pwd)"
ENTRYPOINT="$REPO_DIR/entrypoint.sh"
BASE_FIXTURES="$ROOT_DIR/fixtures/base"
STUBS="$ROOT_DIR/stubs"

FAILURES=0

# --- assertions -----------------------------------------------------------
_fail_assert() {
  FAILURES=$(( FAILURES + 1 ))
  echo "    ASSERTION FAILED: $*" >&2
}

assert_eq() { # expected actual [label]
  if [ "$1" != "$2" ]; then
    _fail_assert "${3:-values differ}"
    echo "      expected: [$1]" >&2
    echo "      actual:   [$2]" >&2
  fi
}

assert_contains() { # haystack needle [label]
  case "$1" in
    *"$2"*) : ;;
    *) _fail_assert "${3:-missing substring}"
       echo "      wanted substring: [$2]" >&2
       echo "      in: [$1]" >&2 ;;
  esac
}

assert_not_contains() { # haystack needle [label]
  case "$1" in
    *"$2"*) _fail_assert "${3:-unexpected substring}"
            echo "      unwanted substring: [$2]" >&2
            echo "      in: [$1]" >&2 ;;
    *) : ;;
  esac
}

assert_status() { # expected-exit-code [label]
  if [ "$1" -ne "$STATUS" ]; then
    _fail_assert "${2:-exit status}"
    echo "      expected exit: $1, actual: $STATUS" >&2
    echo "      stderr: $ERR" >&2
  fi
}

# assert_info FIELD VALUE : the action prints aligned "vulnara:   <field> <value>"
# detail lines; this rebuilds one with the script's own padding.
assert_info() {
  local line; line="$(printf 'vulnara:   %-12s %s' "$1" "$2")"
  assert_contains "$ERR" "$line" "${3:-info line for $1}"
}

assert_success() { assert_status 0 "${1:-expected the action to succeed}"; }
assert_failure() {
  if [ "$STATUS" -eq 0 ]; then
    _fail_assert "${1:-expected the action to fail}"
    echo "      stderr: $ERR" >&2
  fi
}

# --- workspace ------------------------------------------------------------
# Creates WORKDIR/FIXTURE_DIR/STUB_DIR and seeds the base fixtures.
setup_workspace() {
  WORKDIR="$(mktemp -d)"
  FIXTURE_DIR="$WORKDIR/fixtures"
  STUB_DIR="$WORKDIR/stub"
  mkdir -p "$FIXTURE_DIR" "$STUB_DIR"
  cp "$BASE_FIXTURES"/*.json "$FIXTURE_DIR/"
  : > "$STUB_DIR/requests.log"
  : > "$STUB_DIR/graphql.log"
  : > "$STUB_DIR/sleep.log"
  export FIXTURE_DIR STUB_DIR
}

teardown_workspace() { [ -z "${WORKDIR:-}" ] || rm -rf "$WORKDIR"; }

# fixture <name> : replace a canned response, body read from stdin
fixture() { cat > "$FIXTURE_DIR/$1"; }
# drop_fixture <name> : remove a canned response file
drop_fixture() { rm -f "$FIXTURE_DIR/$1"; }

# --- action environment ---------------------------------------------------
# GitHub exposes Docker-action inputs as INPUT_<NAME> with dashes preserved.
# Bash cannot export a name containing a dash, so the harness keeps the input
# environment in an array and injects it with env(1) for every run.
declare -a ENV_ARGS=()

env_set() { # NAME VALUE
  local name="$1" value="$2" i out=()
  for i in "${ENV_ARGS[@]:-}"; do
    [ -n "$i" ] || continue
    case "$i" in "$name="*) continue ;; esac
    out+=("$i")
  done
  out+=("$name=$value")
  ENV_ARGS=("${out[@]}")
}

env_unset() { # NAME
  local name="$1" i out=()
  for i in "${ENV_ARGS[@]:-}"; do
    [ -n "$i" ] || continue
    case "$i" in "$name="*) continue ;; esac
    out+=("$i")
  done
  ENV_ARGS=("${out[@]:-}")
  unset "$name" 2>/dev/null || true
}

# Baseline environment for a run. Tests override individual INPUT_* vars.
default_inputs() {
  ENV_ARGS=()
  env_set "INPUT_SERVICE-ACCOUNT" "ci-bot"
  env_set "INPUT_TOKEN"           "not-a-real-token"
  env_set "INPUT_TENANT"          "tenant-abc"
  env_set "INPUT_SCAN-TOOLS"      "AEGIS"
  env_set "INPUT_BRANCH"          "feature/x"
  env_set "INPUT_REPOSITORY"      "acme/widgets"
  env_set "INPUT_GIT-TOKEN-ID"    ""
  env_set "INPUT_FAIL-ON"         "critical"
  env_set "INPUT_CREATE-ISSUE"    "false"
  env_set "INPUT_AUTO-REMEDIATE"  "false"
  env_set "INPUT_WAIT-TIMEOUT"    "1800"
  env_set "INPUT_POLL-INTERVAL"   "1"
  env_set "INPUT_APP-URL"         "https://app.example.test"
  env_set "INPUT_GATEWAY-URL"     "https://gw.example.test/graphql"
  env_set "INPUT_TOKEN-URL"       "https://auth.example.test/application/o/token/"
  env_set "INPUT_OAUTH-CLIENT-ID" "test-client-id"
  unset GITHUB_REF_NAME GITHUB_REPOSITORY GITHUB_OUTPUT GITHUB_STEP_SUMMARY
}

# --- running the action ---------------------------------------------------
# run_action : execute entrypoint.sh with the stubbed curl/sleep on PATH.
# Sets OUT, ERR and STATUS.
run_action() {
  local outf="$WORKDIR/stdout" errf="$WORKDIR/stderr"
  STATUS=0
  env "${ENV_ARGS[@]}" "PATH=$STUBS:$PATH" "FIXTURE_DIR=$FIXTURE_DIR" "STUB_DIR=$STUB_DIR" \
    bash "$ENTRYPOINT" >"$outf" 2>"$errf" || STATUS=$?
  # shellcheck disable=SC2034  # OUT is asserted on by tests
  OUT="$(cat "$outf")"
  ERR="$(cat "$errf")"
}

# graphql_bodies : every GraphQL request body sent during the run
graphql_bodies() { cut -f2- "$STUB_DIR/graphql.log"; }
# graphql_body_for <op> : request bodies for one GraphQL operation
graphql_body_for() { awk -F'\t' -v op="$1" '$1==op{ sub(/^[^\t]*\t/,""); print }' "$STUB_DIR/graphql.log"; }
# graphql_count [op] : number of GraphQL requests, optionally for one operation
graphql_count() {
  if [ $# -eq 0 ]; then grep -c . "$STUB_DIR/graphql.log" || true
  else awk -F'\t' -v op="$1" '$1==op{n++} END{print n+0}' "$STUB_DIR/graphql.log"; fi
}
# request_count : number of curl invocations
request_count() { grep -c '^REQUEST' "$STUB_DIR/requests.log" || true; }
# requests_log : the raw curl invocation log
requests_log() { cat "$STUB_DIR/requests.log"; }
# sleep_count : how many times the polling loop slept
sleep_count() { grep -c . "$STUB_DIR/sleep.log" || true; }
# summary_file / output_file contents
summary() { cat "${GITHUB_STEP_SUMMARY:-/dev/null}" 2>/dev/null || true; }
outputs()  { cat "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null || true; }

# --- unit-test seam -------------------------------------------------------
# The action is a single script with no library to import, so unit tests
# source everything above the "main" marker line. That region only defines
# functions and resolves inputs; it performs no network I/O. The snippet runs
# in a child shell so the dashed INPUT_* variables can be injected with env(1).
prelude_file() {
  awk '/^# ={10,}$/{exit} {print}' "$ENTRYPOINT" > "$WORKDIR/prelude.sh"
  printf '%s' "$WORKDIR/prelude.sh"
}

# prelude_run '<bash code>' : source the prelude, then run the snippet
prelude_run() {
  local lib; lib="$(prelude_file)"
  env "${ENV_ARGS[@]}" "PATH=$STUBS:$PATH" "FIXTURE_DIR=$FIXTURE_DIR" "STUB_DIR=$STUB_DIR" \
    bash -c 'source "$1"; set +e; eval "$2"' _ "$lib" "$1" 2>"$WORKDIR/prelude.err"
}

# prelude_var NAME : value of a variable resolved by the prelude
prelude_var() { prelude_run "printf '%s' \"\${$1-}\""; }

# prelude_call fn args... : stdout of a prelude function
prelude_call() { prelude_run "$*"; }
