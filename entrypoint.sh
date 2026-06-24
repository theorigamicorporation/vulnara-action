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

# --- console polish -------------------------------------------------------
STEP_TOTAL=5
step()     { echo "" >&2; echo "vulnara: [$1/${STEP_TOTAL}] $2" >&2; }
info()     { printf 'vulnara:   %-12s %s\n' "$1" "$2" >&2; }
ok()       { echo "vulnara:   ✓ $*" >&2; }
warn()     { echo "::warning::$*" >&2; }
group()    { echo "::group::$*" >&2; }
endgroup() { echo "::endgroup::" >&2; }
hr()       { echo "vulnara: ========================================" >&2; }

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
  JWT_TTL="$exp"
}
JWT_TTL=0

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

# --- resolve the Vulnara repository (populates REPO_* globals) -------------
REPO_ID=""; REPO_FULLNAME=""; REPO_PROVIDER=""; REPO_VISIBILITY=""
REPO_ENABLED=""; REPO_LANGS=""; REPO_URL=""; REPO_ENTITY=""
resolve_repository() {
  local owner="${REPOSITORY%%/*}" name="${REPOSITORY##*/}" data item
  data="$(gql "$(jq -n --arg n "$name" \
    '{query:"query($l:List){repositories(list:$l){items{id repositoryName private enabled programmingLanguage cloneUrl gitEntity{__typename ... on Organization{name gitType htmlUrl} ... on GitUser{name gitType htmlUrl}}}}}",
      variables:{l:{filters:[{field:"repositoryName",stringEquals:$n}]}}}')")"
  item="$(echo "$data" | jq -c --arg o "$(echo "$owner" | tr '[:upper:]' '[:lower:]')" \
    '([.repositories.items[] | select(((.gitEntity.name // "") | ascii_downcase) == $o)][0])
       // (.repositories.items[0]) // empty')"
  [ -n "$item" ] || fail "repository '$REPOSITORY' was not found in Vulnara (tenant '$TENANT'). Add it in Vulnara first."
  REPO_ID="$(echo "$item" | jq -r '.id')"
  REPO_ENTITY="$(echo "$item" | jq -r '.gitEntity.name // "?"')"
  REPO_FULLNAME="$REPO_ENTITY/$(echo "$item" | jq -r '.repositoryName')"
  REPO_PROVIDER="$(echo "$item" | jq -r '.gitEntity.gitType // "?"')"
  REPO_VISIBILITY="$(echo "$item" | jq -r 'if .private == true then "private" elif .private == false then "public" else "unknown" end')"
  REPO_ENABLED="$(echo "$item" | jq -r 'if .enabled == false then "no" else "yes" end')"
  REPO_LANGS="$(echo "$item" | jq -r '(.programmingLanguage // []) | join(", ") | if . == "" then "n/a" else . end')"
  local entity_url clone_url rname
  entity_url="$(echo "$item" | jq -r '.gitEntity.htmlUrl // ""')"
  clone_url="$(echo "$item" | jq -r '.cloneUrl // ""')"
  rname="$(echo "$item" | jq -r '.repositoryName')"
  if [ -n "$entity_url" ]; then
    REPO_URL="${entity_url%/}/$rname"
  elif [ -n "$clone_url" ]; then
    REPO_URL="${clone_url%.git}"
  else
    REPO_URL=""
  fi
}

# --- resolve scan tools (by name or id); echo "id<TAB>name" per line -------
resolve_tools() {
  local data; data="$(gql '{"query":"{dockerScanTools(list:{}){items{id name}}}"}')"
  local found=0
  IFS=',' read -ra wanted <<< "$SCAN_TOOLS"
  for raw in "${wanted[@]}"; do
    local t; t="$(echo "$raw" | sed 's/^ *//;s/ *$//')"
    [ -n "$t" ] || continue
    local pair
    pair="$(echo "$data" | jq -r --arg t "$t" \
      '[.dockerScanTools.items[] | select(.id == $t or (.name | ascii_downcase) == ($t | ascii_downcase))][0] | select(.) | "\(.id)\t\(.name)"')"
    [ -n "$pair" ] || fail "scan tool '$t' not found. Available: $(echo "$data" | jq -r '[.dockerScanTools.items[].name] | join(", ")')"
    echo "$pair"
    found=1
  done
  [ "$found" -eq 1 ] || fail "no scan tools provided"
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

# --- wait for a scan to reach a terminal state; echo elapsed seconds -------
wait_scan() {
  local srid="$1" label="$2" start; start="$(date +%s)"
  local deadline=$(( start + WAIT_TIMEOUT )) status last=""
  while :; do
    status="$(gql "$(jq -n --arg id "$srid" '{query:"query($id:ID!){scanResult(id:$id){status}}",variables:{id:$id}}')" \
      | jq -r '.scanResult.status // "PENDING"')"
    local now; now="$(date +%s)"
    case "$(echo "$status" | tr '[:lower:]' '[:upper:]')" in
      SUCCESS) echo $(( now - start )); return 0 ;;
      FAILED|CANCELLED) fail "scan for '$label' ended as $status (id $srid)" ;;
    esac
    if [ "$status" != "$last" ]; then info "$label" "$status ($(( now - start ))s elapsed)"; last="$status"; fi
    [ "$now" -lt "$deadline" ] || fail "timed out after ${WAIT_TIMEOUT}s waiting for '$label' (still $status, id $srid)"
    sleep "$POLL_INTERVAL"
  done
}

sev_label() {
  case "$1" in CRITICAL) echo "Critical";; HIGH) echo "High";; MEDIUM) echo "Medium";; LOW) echo "Low";; *) echo "none";; esac
}

# ===========================================================================
RUN_START="$(date +%s)"
hr
log "Vulnara security scan"
hr

# --- [1/5] authenticate ----------------------------------------------------
step 1 "Authenticate service account"
ensure_jwt
ok "authenticated as '$SERVICE_ACCOUNT' (tenant '$TENANT'), token valid ~${JWT_TTL}s"

# --- [2/5] resolve repository ----------------------------------------------
step 2 "Resolve repository in Vulnara"
resolve_repository
info "Repository" "$REPO_FULLNAME"
info "Vulnara id" "$REPO_ID"
info "Provider" "$REPO_PROVIDER"
info "Visibility" "$REPO_VISIBILITY"
info "Branch" "$BRANCH"
info "Languages" "$REPO_LANGS"
info "Enabled" "$REPO_ENABLED"
[ -z "$REPO_URL" ] || info "URL" "$REPO_URL"
if [ "$REPO_ENABLED" = "no" ]; then
  warn "repository '$REPO_FULLNAME' is disabled in Vulnara; the scan will likely be rejected. Enable it first."
fi
if [ "$REPO_VISIBILITY" = "private" ] && [ -z "$GIT_TOKEN_ID" ]; then
  warn "repository is private but no git-token-id was provided; cloning may fail."
fi
ok "resolved '$REPO_FULLNAME'"

# --- [3/5] resolve scan tools ----------------------------------------------
step 3 "Resolve scan tools"
declare -a TOOL_IDS=() TOOL_NAMES=()
while IFS=$'\t' read -r tid tname; do
  [ -n "$tid" ] || continue
  TOOL_IDS+=("$tid"); TOOL_NAMES+=("$tname")
  info "tool" "$tname ($tid)"
done < <(resolve_tools)
ok "${#TOOL_IDS[@]} scan tool(s) selected"

# --- [4/5] start + wait for scans ------------------------------------------
step 4 "Run scans on branch '$BRANCH'"
declare -a SCANS=() SCAN_LABELS=() SCAN_DURATIONS=()
SCAN_IDS=""
for i in "${!TOOL_IDS[@]}"; do
  tname="${TOOL_NAMES[$i]}"
  srid="$(start_scan "${TOOL_IDS[$i]}")"
  [ -n "$srid" ] || fail "scan did not return a scan result id (tool '$tname')"
  SCANS+=("$srid"); SCAN_LABELS+=("$tname")
  SCAN_IDS="$SCAN_IDS $srid"
  ok "started '$tname' -> scan $srid"
done
SCAN_IDS="$(echo "$SCAN_IDS" | sed 's/^ *//')"

log "waiting for ${#SCANS[@]} scan(s) to finish (timeout ${WAIT_TIMEOUT}s, polling every ${POLL_INTERVAL}s)"
for i in "${!SCANS[@]}"; do
  dur="$(wait_scan "${SCANS[$i]}" "${SCAN_LABELS[$i]}")"
  SCAN_DURATIONS+=("$dur")
  ok "${SCAN_LABELS[$i]} completed in ${dur}s"
done

# --- [5/5] collect findings + gate -----------------------------------------
step 5 "Evaluate findings"
HIGHEST=0; HIGHEST_NAME="NONE"
declare -A SEV_TOTAL=( [CRITICAL]=0 [HIGH]=0 [MEDIUM]=0 [LOW]=0 )
declare -a SCAN_FINDINGS=()
for srid in "${SCANS[@]}"; do
  data="$(gql "$(jq -n --arg id "$srid" \
    '{query:"query($l:List){scanFindings(list:$l){items{severity}}}",variables:{l:{filters:[{field:"scanResultId",stringEquals:$id}]}}}')")"
  cnt=0
  while read -r sev; do
    [ -n "$sev" ] || continue
    cnt=$(( cnt + 1 ))
    up="$(echo "$sev" | tr '[:lower:]' '[:upper:]')"
    case "$up" in CRITICAL|HIGH|MEDIUM|LOW) SEV_TOTAL[$up]=$(( ${SEV_TOTAL[$up]:-0} + 1 )) ;; esac
    r="$(sev_rank "$up")"
    if [ "$r" -gt "$HIGHEST" ]; then HIGHEST="$r"; HIGHEST_NAME="$up"; fi
  done < <(echo "$data" | jq -r '.scanFindings.items[].severity')
  SCAN_FINDINGS+=("$cnt")
done

TOTAL=$(( SEV_TOTAL[CRITICAL] + SEV_TOTAL[HIGH] + SEV_TOTAL[MEDIUM] + SEV_TOTAL[LOW] ))
PASSED="true"
if [ "$HIGHEST" -ge "$FAIL_RANK" ]; then PASSED="false"; fi
RUN_TIME=$(( $(date +%s) - RUN_START ))
HIGHEST_LABEL="$(sev_label "$HIGHEST_NAME")"

info "Critical" "${SEV_TOTAL[CRITICAL]}"
info "High" "${SEV_TOTAL[HIGH]}"
info "Medium" "${SEV_TOTAL[MEDIUM]}"
info "Low" "${SEV_TOTAL[LOW]}"
info "Total" "$TOTAL"
info "Highest" "$HIGHEST_LABEL"

# --- outputs ---------------------------------------------------------------
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "scan-result-ids=$SCAN_IDS"
    echo "highest-severity=$(echo "$HIGHEST_NAME" | tr '[:upper:]' '[:lower:]')"
    echo "passed=$PASSED"
  } >> "$GITHUB_OUTPUT"
fi

# --- job summary -----------------------------------------------------------
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  if [ "$PASSED" = "true" ]; then verdict="Passed"; badge="✅"; else verdict="Failed"; badge="❌"; fi
  repo_md="\`$REPO_FULLNAME\`"
  [ -z "$REPO_URL" ] || repo_md="[\`$REPO_FULLNAME\`]($REPO_URL)"
  {
    echo "## $badge Vulnara scan: $verdict"
    echo ""
    echo "| | |"
    echo "|---|---|"
    echo "| Repository | $repo_md |"
    echo "| Provider | $REPO_PROVIDER ($REPO_VISIBILITY) |"
    echo "| Branch | \`$BRANCH\` |"
    echo "| Languages | $REPO_LANGS |"
    echo "| Gate | \`fail-on: $FAIL_ON\` |"
    echo "| Highest severity | **$HIGHEST_LABEL** |"
    echo "| Duration | ${RUN_TIME}s |"
    echo ""
    echo "### Findings"
    echo ""
    echo "| Critical | High | Medium | Low | Total |"
    echo "|---|---|---|---|---|"
    echo "| ${SEV_TOTAL[CRITICAL]} | ${SEV_TOTAL[HIGH]} | ${SEV_TOTAL[MEDIUM]} | ${SEV_TOTAL[LOW]} | $TOTAL |"
    echo ""
    echo "### Scans"
    echo ""
    echo "| Tool | Duration | Findings | Scan result id |"
    echo "|---|---|---|---|"
    for i in "${!SCANS[@]}"; do
      echo "| ${SCAN_LABELS[$i]} | ${SCAN_DURATIONS[$i]:-?}s | ${SCAN_FINDINGS[$i]:-0} | \`${SCANS[$i]}\` |"
    done
  } >> "$GITHUB_STEP_SUMMARY"
fi

hr
log "findings -> critical=${SEV_TOTAL[CRITICAL]} high=${SEV_TOTAL[HIGH]} medium=${SEV_TOTAL[MEDIUM]} low=${SEV_TOTAL[LOW]} (total $TOTAL) in ${RUN_TIME}s"
if [ "$PASSED" = "false" ]; then
  fail "scan gate failed: highest severity '$HIGHEST_LABEL' meets/exceeds fail-on '$FAIL_ON'"
fi
log "✓ scan gate passed (fail-on: $FAIL_ON, highest: $HIGHEST_LABEL)"
hr
