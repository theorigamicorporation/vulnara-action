#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Vulnara Scan action. Authenticate a service account (OAuth client_credentials
# -> JWT), resolve the repository, start a scan per tool on the branch, wait for
# them to finish, and gate the build on the highest finding severity. Talks to
# the Vulnara GraphQL gateway directly (curl + jq).
# ---------------------------------------------------------------------------

log()  { echo "vulnara: $*" >&2; }
fail() { echo "::error::$*" >&2; exit 1; }

# GitHub passes Docker-action inputs as INPUT_<NAME> with dashes kept
# (service-account -> INPUT_SERVICE-ACCOUNT), which bash can't read with ${...}.
# Read via printenv, falling back to the underscore form.
input() {
  local up; up="$(echo "$1" | tr '[:lower:]' '[:upper:]')"
  local v; v="$(printenv "INPUT_$up" 2>/dev/null || true)"
  if [ -z "$v" ]; then v="$(printenv "INPUT_$(echo "$up" | tr '-' '_')" 2>/dev/null || true)"; fi
  printf '%s' "$v"
}

# --- config (overridable for non-prod) ------------------------------------
TOKEN_URL="$(input token-url)";       [ -n "$TOKEN_URL" ]   || TOKEN_URL="https://auth.theorigamicorporation.com/application/o/token/"
GATEWAY_URL="$(input gateway-url)";   [ -n "$GATEWAY_URL" ] || GATEWAY_URL="https://vulnara-gw.rso.dev/graphql"
CLIENT_ID="$(input oauth-client-id)"; [ -n "$CLIENT_ID" ]   || CLIENT_ID="hl04e6MSMRY60LdpGh5rdMRQjkPxvldAYoqXdzo4"

# --- inputs ---------------------------------------------------------------
SERVICE_ACCOUNT="$(input service-account)"
TOKEN="$(input token)"
TENANT="$(input tenant)"
SCAN_TOOLS="$(input scan-tools)"
BRANCH="$(input branch)";         [ -n "$BRANCH" ]     || BRANCH="${GITHUB_REF_NAME:-}"
REPOSITORY="$(input repository)";  [ -n "$REPOSITORY" ] || REPOSITORY="${GITHUB_REPOSITORY:-}"
GIT_TOKEN_ID="$(input git-token-id)"
FAIL_ON="$(input fail-on | tr '[:upper:]' '[:lower:]')"; [ -n "$FAIL_ON" ] || FAIL_ON="critical"
CREATE_ISSUE="$(input create-issue)";     [ -n "$CREATE_ISSUE" ]   || CREATE_ISSUE="false"
AUTO_REMEDIATE="$(input auto-remediate)"; [ -n "$AUTO_REMEDIATE" ] || AUTO_REMEDIATE="false"
WAIT_TIMEOUT="$(input wait-timeout)";     [ -n "$WAIT_TIMEOUT" ]   || WAIT_TIMEOUT="1800"
POLL_INTERVAL="$(input poll-interval)";   [ -n "$POLL_INTERVAL" ]  || POLL_INTERVAL="15"

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

# --- auth: client_credentials -> JWT (refreshed before expiry) ------------
JWT=""; JWT_EXP=0
ensure_jwt() {
  if [ "$(date +%s)" -lt "$(( JWT_EXP - 120 ))" ]; then return 0; fi
  local resp
  resp="$(curl -sS "$TOKEN_URL" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=$CLIENT_ID" \
    --data-urlencode "username=$SERVICE_ACCOUNT" \
    --data-urlencode "password=$TOKEN" \
    --data-urlencode "scope=profile")"
  JWT="$(echo "$resp" | jq -r '.access_token // empty')"
  if [ -z "$JWT" ]; then
    echo "$resp" | jq -r '.error_description // .error // .' >&2
    fail "could not authenticate the service account (check service-account/token/tenant)"
  fi
  local exp; exp="$(echo "$resp" | jq -r '.expires_in // 3600')"
  JWT_EXP=$(( $(date +%s) + exp ))
}

# --- gql: run a request body, echo .data, fail on .errors -----------------
gql() {
  ensure_jwt
  local resp
  resp="$(curl -sS "$GATEWAY_URL" \
    -H "Authorization: Bearer $JWT" -H "X-Tenant: $TENANT" \
    -H 'Content-Type: application/json' --data "$1")"
  if echo "$resp" | jq -e '.errors' >/dev/null 2>&1; then
    echo "$resp" | jq -r '.errors[] | "  \(.extensions.code // "ERROR"): \(.message)"' >&2
    fail "GraphQL request failed"
  fi
  echo "$resp" | jq '.data'
}

# --- resolve the Vulnara repository id ------------------------------------
resolve_repository() {
  local owner="${REPOSITORY%%/*}" name="${REPOSITORY##*/}" data id
  data="$(gql "$(jq -n --arg n "$name" \
    '{query:"query($l:List){repositories(list:$l){items{id repositoryName gitEntity{__typename ... on Organization{name} ... on GitUser{name}}}}}",
      variables:{l:{filters:[{field:"repositoryName",stringEquals:$n}]}}}')")"
  id="$(echo "$data" | jq -r --arg o "$(echo "$owner" | tr '[:upper:]' '[:lower:]')" \
    '([.repositories.items[] | select(((.gitEntity.name // "") | ascii_downcase) == $o)][0].id)
       // (.repositories.items[0].id) // empty')"
  [ -n "$id" ] || fail "repository '$REPOSITORY' was not found in Vulnara (tenant '$TENANT'). Add it in Vulnara first."
  echo "$id"
}

# --- resolve scan tools (by name or id) -----------------------------------
resolve_tools() {
  local data; data="$(gql '{"query":"{dockerScanTools(list:{}){items{id name}}}"}')"
  local out=""
  IFS=',' read -ra wanted <<< "$SCAN_TOOLS"
  for raw in "${wanted[@]}"; do
    local t; t="$(echo "$raw" | sed 's/^ *//;s/ *$//')"
    [ -n "$t" ] || continue
    local id
    id="$(echo "$data" | jq -r --arg t "$t" \
      '[.dockerScanTools.items[] | select(.id == $t or (.name | ascii_downcase) == ($t | ascii_downcase))][0].id // empty')"
    [ -n "$id" ] || fail "scan tool '$t' not found. Available: $(echo "$data" | jq -r '[.dockerScanTools.items[].name] | join(", ")')"
    out="$out $id"
  done
  [ -n "$out" ] || fail "no scan tools provided"
  echo "$out"
}

# --- start a scan, echo the scan result id --------------------------------
start_scan() {
  local tool_id="$1" ci ar input
  ci=false; if [ "$CREATE_ISSUE" = "true" ]; then ci=true; fi
  ar=false; if [ "$AUTO_REMEDIATE" = "true" ]; then ar=true; fi
  input="$(jq -n --arg r "$REPO_ID" --arg t "$tool_id" --arg b "$BRANCH" \
    --argjson ci "$ci" --argjson ar "$ar" --arg gt "$GIT_TOKEN_ID" \
    '{repositoryId:$r, dockerScanToolId:$t, branch:$b, createIssue:$ci, autoRemediate:$ar}
       + (if $gt == "" then {} else {gitTokenId:$gt} end)')"
  gql "$(jq -n --argjson i "$input" \
    '{query:"mutation($i:StartRepositoryScanInput!){startRepositoryScan(input:$i){scanResult{id status}}}",variables:{i:$i}}')" \
    | jq -r '.startRepositoryScan.scanResult.id // empty'
}

# --- wait for a scan to reach a terminal state ----------------------------
wait_scan() {
  local srid="$1" deadline=$(( $(date +%s) + WAIT_TIMEOUT )) status
  while :; do
    status="$(gql "$(jq -n --arg id "$srid" '{query:"query($id:ID!){scanResult(id:$id){status}}",variables:{id:$id}}')" \
      | jq -r '.scanResult.status // "PENDING"')"
    case "$(echo "$status" | tr '[:lower:]' '[:upper:]')" in
      SUCCESS) return 0 ;;
      FAILED|CANCELLED|ERROR) fail "scan $srid ended as $status" ;;
    esac
    [ "$(date +%s)" -lt "$deadline" ] || fail "timed out waiting for scan $srid (still $status)"
    sleep "$POLL_INTERVAL"
  done
}

# ---------------------------------------------------------------------------
log "resolving repository '$REPOSITORY'"
REPO_ID="$(resolve_repository)"
log "repository id: $REPO_ID"
TOOLS="$(resolve_tools)"

declare -a SCANS=()
SCAN_IDS=""
for tool_id in $TOOLS; do
  log "starting scan (tool $tool_id, branch '$BRANCH')"
  srid="$(start_scan "$tool_id")"
  [ -n "$srid" ] || fail "scan did not return a scan result id (tool $tool_id)"
  SCANS+=("$srid")
  SCAN_IDS="$SCAN_IDS $srid"
  log "  scan result id: $srid"
done
SCAN_IDS="$(echo "$SCAN_IDS" | sed 's/^ *//')"

log "waiting for scans to finish (timeout ${WAIT_TIMEOUT}s)"
for srid in "${SCANS[@]}"; do
  wait_scan "$srid"
  log "  $srid -> SUCCESS"
done

# --- collect findings + gate ----------------------------------------------
HIGHEST=0; HIGHEST_NAME="none"
declare -A SEV_TOTAL=( [CRITICAL]=0 [HIGH]=0 [MEDIUM]=0 [LOW]=0 )
for srid in "${SCANS[@]}"; do
  data="$(gql "$(jq -n --arg id "$srid" \
    '{query:"query($l:List){scanFindings(list:$l){items{severity}}}",variables:{l:{filters:[{field:"scanResultId",stringEquals:$id}]}}}')")"
  while read -r sev; do
    [ -n "$sev" ] || continue
    up="$(echo "$sev" | tr '[:lower:]' '[:upper:]')"
    case "$up" in CRITICAL|HIGH|MEDIUM|LOW) SEV_TOTAL[$up]=$(( ${SEV_TOTAL[$up]:-0} + 1 )) ;; esac
    r="$(sev_rank "$up")"
    if [ "$r" -gt "$HIGHEST" ]; then HIGHEST="$r"; HIGHEST_NAME="$up"; fi
  done < <(echo "$data" | jq -r '.scanFindings.items[].severity')
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
