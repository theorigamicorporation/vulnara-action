#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Vulnara Scan action. Wraps vulnara-cli: authenticate as a service account,
# resolve the repository, start a scan per tool on the branch, wait for them to
# finish, and gate the build on the highest finding severity.
# ---------------------------------------------------------------------------

CLI_REPO="theorigamicorporation/vulnara-cli"
CLI_BIN="/usr/local/bin/vulnara-cli"
WORK="$(mktemp -d)"

log()  { echo "vulnara: $*" >&2; }
fail() { echo "::error::$*" >&2; exit 1; }

# --- inputs ---------------------------------------------------------------
SERVICE_ACCOUNT="${INPUT_SERVICE_ACCOUNT:-}"
TOKEN="${INPUT_TOKEN:-}"
TENANT="${INPUT_TENANT:-}"
SCAN_TOOLS="${INPUT_SCAN_TOOLS:-}"
BRANCH="${INPUT_BRANCH:-${GITHUB_REF_NAME:-}}"
REPOSITORY="${INPUT_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
GIT_TOKEN_ID="${INPUT_GIT_TOKEN_ID:-}"
FAIL_ON="$(echo "${INPUT_FAIL_ON:-critical}" | tr '[:upper:]' '[:lower:]')"
CREATE_ISSUE="${INPUT_CREATE_ISSUE:-false}"
AUTO_REMEDIATE="${INPUT_AUTO_REMEDIATE:-false}"
WAIT_TIMEOUT="${INPUT_WAIT_TIMEOUT:-1800}"
POLL_INTERVAL="${INPUT_POLL_INTERVAL:-15}"
CLI_VERSION="${INPUT_CLI_VERSION:-latest}"
CLI_TOKEN="${INPUT_CLI_TOKEN:-}"

[ -n "$SERVICE_ACCOUNT" ] || fail "service-account is required"
[ -n "$TOKEN" ]           || fail "token is required"
[ -n "$TENANT" ]          || fail "tenant is required"
[ -n "$SCAN_TOOLS" ]      || fail "scan-tools is required"
[ -n "$REPOSITORY" ]      || fail "repository could not be determined"
[ -n "$BRANCH" ]          || fail "branch could not be determined"

# --- severity helpers -----------------------------------------------------
sev_rank() {
  case "$(echo "${1:-}" | tr '[:lower:]' '[:upper:]')" in
    CRITICAL) echo 4 ;; HIGH) echo 3 ;; MEDIUM) echo 2 ;; LOW) echo 1 ;; *) echo 0 ;;
  esac
}
case "$FAIL_ON" in
  none) FAIL_RANK=99 ;; low) FAIL_RANK=1 ;; medium) FAIL_RANK=2 ;;
  high) FAIL_RANK=3 ;; critical) FAIL_RANK=4 ;;
  *) fail "invalid fail-on '$FAIL_ON' (expected none|low|medium|high|critical)" ;;
esac

# --- download the CLI -----------------------------------------------------
install_cli() {
  local base="https://github.com/${CLI_REPO}/releases"
  local url
  if [ "$CLI_VERSION" = "latest" ]; then
    url="${base}/latest/download/vulnara-cli_Linux_x86_64.tar.gz"
  else
    url="${base}/download/${CLI_VERSION}/vulnara-cli_Linux_x86_64.tar.gz"
  fi
  log "downloading vulnara-cli (${CLI_VERSION})"
  local auth=()
  if [ -n "$CLI_TOKEN" ]; then auth=(-H "Authorization: Bearer ${CLI_TOKEN}"); fi
  curl -fsSL "${auth[@]}" "$url" -o "$WORK/cli.tgz" \
    || fail "failed to download vulnara-cli from $url"
  tar -xzf "$WORK/cli.tgz" -C "$WORK"
  local bin
  bin="$(find "$WORK" -type f -name 'vulnara-cli' | head -1)"
  [ -n "$bin" ] || fail "vulnara-cli binary not found in release archive"
  install -m 0755 "$bin" "$CLI_BIN"
}

# --- auth setup -----------------------------------------------------------
setup_auth() {
  mkdir -p "$HOME/.config/vulnara/sa" "$HOME/.config/vulnara/jwt" "$HOME/.config/vulnara/tenant"
  jq -n --arg u "$SERVICE_ACCOUNT" --arg p "$TOKEN" \
    '{username: $u, password: $p}' > "$HOME/.config/vulnara/sa/service_account.json"
  printf '%s' "$TENANT" > "$HOME/.config/vulnara/tenant/default_tenant"
}

# --- run a CLI command, capture clean JSON to a file ----------------------
# usage: vcli <outfile> <command> [args...]
vcli() {
  local out="$1"; shift
  local cmd="$1"
  rm -f "$out"
  if ! "$CLI_BIN" "$@" --tenant "$TENANT" --output "$out" >"$WORK/cli.log" 2>&1; then
    cat "$WORK/cli.log" >&2
    fail "vulnara-cli $cmd failed"
  fi
  if [ ! -s "$out" ] || ! jq -e . "$out" >/dev/null 2>&1; then
    cat "$WORK/cli.log" >&2
    fail "vulnara-cli $cmd returned no usable result"
  fi
}

# --- resolve the Vulnara repository id ------------------------------------
# The repositories query exposes repositoryName + gitEntity.name (the workspace,
# i.e. the GitHub owner), so match on those.
resolve_repository() {
  local owner="${REPOSITORY%%/*}" name="${REPOSITORY##*/}"
  vcli "$WORK/repos.json" repositories --filters "repositoryName=$name"
  local id
  id="$(jq -r --arg o "$(echo "$owner" | tr '[:upper:]' '[:lower:]')" \
    '[.repositories.items[] | select(((.gitEntity.name // "") | ascii_downcase) == $o)][0].id // empty' \
    "$WORK/repos.json")"
  if [ -z "$id" ]; then
    # fall back to the only match if the workspace name differs from the owner
    id="$(jq -r '.repositories.items[0].id // empty' "$WORK/repos.json")"
  fi
  [ -n "$id" ] || fail "repository '$REPOSITORY' was not found in Vulnara (tenant '$TENANT'). Add it in Vulnara first."
  echo "$id"
}

# --- scan tool ids --------------------------------------------------------
resolve_tools() {
  local out=""
  IFS=',' read -ra wanted <<< "$SCAN_TOOLS"
  for raw in "${wanted[@]}"; do
    local t; t="$(echo "$raw" | sed 's/^ *//;s/ *$//')"
    if [ -n "$t" ]; then out="$out $t"; fi
  done
  [ -n "$out" ] || fail "no scan tool ids provided in scan-tools"
  echo "$out"
}

# ---------------------------------------------------------------------------
install_cli
setup_auth

log "resolving repository '$REPOSITORY'"
REPO_ID="$(resolve_repository)"
log "repository id: $REPO_ID"

TOOLS="$(resolve_tools)"

EXTRA=()
if [ -n "$GIT_TOKEN_ID" ];          then EXTRA+=(--gitTokenId "$GIT_TOKEN_ID"); fi
if [ "$CREATE_ISSUE" = "true" ];    then EXTRA+=(--createIssue=true); fi
if [ "$AUTO_REMEDIATE" = "true" ];  then EXTRA+=(--autoRemediate=true); fi

declare -a SCANS=()   # "scanResultId|toolId"
SCAN_IDS=""
for tool_id in $TOOLS; do
  log "starting scan: tool='$tool_id' branch='$BRANCH'"
  vcli "$WORK/start.json" start_repository_scan \
    --repositoryId "$REPO_ID" --dockerScanToolId "$tool_id" --branch "$BRANCH" "${EXTRA[@]}"
  srid="$(jq -r '.startRepositoryScan.scanResult.id // empty' "$WORK/start.json")"
  [ -n "$srid" ] || fail "scan did not return a scan result id (tool '$tool_id')"
  SCANS+=("$srid|$tool_id")
  SCAN_IDS="$SCAN_IDS $srid"
  log "  scan result id: $srid"
done
SCAN_IDS="$(echo "$SCAN_IDS" | sed 's/^ *//')"

# --- wait for all scans to finish -----------------------------------------
terminal() { case "$(echo "$1" | tr '[:lower:]' '[:upper:]')" in SUCCESS|FAILED|CANCELLED|ERROR) return 0 ;; *) return 1 ;; esac }

log "waiting for scans to finish (timeout ${WAIT_TIMEOUT}s)"
deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
for item in "${SCANS[@]}"; do
  srid="${item%%|*}"; tool="${item#*|}"
  while :; do
    vcli "$WORK/status.json" get_scan_result --id "$srid"
    status="$(jq -r '.scanResult.status // "PENDING"' "$WORK/status.json")"
    if terminal "$status"; then
      log "  '$tool' -> $status"
      [ "$(echo "$status" | tr '[:lower:]' '[:upper:]')" = "SUCCESS" ] || fail "scan for '$tool' ended as $status"
      break
    fi
    [ "$(date +%s)" -lt "$deadline" ] || fail "timed out waiting for scan '$tool' (still $status)"
    sleep "$POLL_INTERVAL"
  done
done

# --- collect findings + gate ----------------------------------------------
HIGHEST=0; HIGHEST_NAME="none"
declare -A SEV_TOTAL=( [CRITICAL]=0 [HIGH]=0 [MEDIUM]=0 [LOW]=0 )
for item in "${SCANS[@]}"; do
  srid="${item%%|*}"
  vcli "$WORK/findings.json" scan_findings --filters "scanResultId=$srid"
  while IFS=$'\t' read -r sev cnt; do
    [ -n "$sev" ] || continue
    up="$(echo "$sev" | tr '[:lower:]' '[:upper:]')"
    case "$up" in CRITICAL|HIGH|MEDIUM|LOW) SEV_TOTAL[$up]=$(( ${SEV_TOTAL[$up]:-0} + cnt )) ;; esac
    r="$(sev_rank "$up")"
    if [ "$r" -gt "$HIGHEST" ]; then HIGHEST="$r"; HIGHEST_NAME="$up"; fi
  done < <(jq -r '.scanFindings.items[].severity' "$WORK/findings.json" 2>/dev/null \
            | sort | uniq -c | awk '{print $2"\t"$1}')
done

TOTAL=$(( SEV_TOTAL[CRITICAL] + SEV_TOTAL[HIGH] + SEV_TOTAL[MEDIUM] + SEV_TOTAL[LOW] ))
PASSED="true"
if [ "$HIGHEST" -ge "$FAIL_RANK" ]; then PASSED="false"; fi

# --- outputs + summary ----------------------------------------------------
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "scan-result-ids=$SCAN_IDS"
    echo "highest-severity=$(echo "$HIGHEST_NAME" | tr '[:upper:]' '[:lower:]')"
    echo "passed=$PASSED"
  } >> "$GITHUB_OUTPUT"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Vulnara scan"
    echo ""
    echo "**Repository:** \`$REPOSITORY\` &nbsp; **Branch:** \`$BRANCH\`"
    echo ""
    echo "| Severity | Count |"
    echo "|---|---|"
    echo "| Critical | ${SEV_TOTAL[CRITICAL]} |"
    echo "| High | ${SEV_TOTAL[HIGH]} |"
    echo "| Medium | ${SEV_TOTAL[MEDIUM]} |"
    echo "| Low | ${SEV_TOTAL[LOW]} |"
    echo ""
    if [ "$PASSED" = "true" ]; then
      echo "Gate (\`fail-on: $FAIL_ON\`): **passed** (highest: $HIGHEST_NAME)."
    else
      echo "Gate (\`fail-on: $FAIL_ON\`): **failed** (highest: $HIGHEST_NAME)."
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

log "findings -> critical=${SEV_TOTAL[CRITICAL]} high=${SEV_TOTAL[HIGH]} medium=${SEV_TOTAL[MEDIUM]} low=${SEV_TOTAL[LOW]} (total $TOTAL)"
if [ "$PASSED" = "false" ]; then
  fail "scan gate failed: found '$HIGHEST_NAME' findings (fail-on: $FAIL_ON)"
fi
log "scan gate passed (fail-on: $FAIL_ON, highest: $HIGHEST_NAME)"
