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
APP_URL="$(input app-url)";           [ -n "$APP_URL" ]     || APP_URL="https://vulnara.rso.dev"
APP_URL="${APP_URL%/}"
FINDING_LIMIT=50
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
# gql_post is the transport and returns the whole response, errors included, so
# a caller that can recover from a specific error can inspect it. Everything
# that cannot recover uses gql and aborts.
gql_post() {
  ensure_jwt
  curl -sS "$GATEWAY_URL" \
    -H "Authorization: Bearer $JWT" -H "X-Tenant: $TENANT" \
    -H 'Content-Type: application/json' --data "$1"
}

gql_errors() {
  echo "$1" | jq -r '.errors[] | "  \(.extensions.code // "ERROR"): \(.message)"' >&2
}

gql() {
  local resp; resp="$(gql_post "$1")"
  if echo "$resp" | jq -e '.errors' >/dev/null 2>&1; then
    gql_errors "$resp"
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
  if [ -n "$entity_url" ] && [ "$REPO_PROVIDER" = "azure_devops" ]; then
    REPO_URL="${entity_url%/}/${rname%%/*}/_git/${rname#*/}"
  elif [ -n "$entity_url" ]; then
    REPO_URL="${entity_url%/}/$rname"
  elif [ -n "$clone_url" ]; then
    REPO_URL="$(echo "${clone_url%.git}" | sed -E 's#^(https?://)[^/@]+@#\1#')"
  else
    REPO_URL=""
  fi
}

# A tool id is a UUID. Used only to tell "you passed an id we do not have" from
# "you passed a name and names are gone", so the failure says which it was.
looks_like_id() {
  [[ "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# --- category display names (the shared vocabulary, not a scanner) ---------
# A scan is labelled by what it looks for, never by what runs it. The codenames
# this used to map, and the stored names behind them, are retired from every
# customer surface, and a workflow log on a public repository is one of those.
# The fallback is `Uncategorised`: display only. It is never stored, never
# filtered on, and is not a category the platform knows about.
category_display() {
  case "$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    sast)    printf 'Code analysis' ;;
    sca)     printf 'Dependencies' ;;
    secrets) printf 'Secrets' ;;
    pii)     printf 'Personal data' ;;
    *)       printf 'Uncategorised' ;;
  esac
}

# A scanner serves one or more categories, so the label for a scan is the set of
# categories its scanner covers. Two categories that render to the same label
# collapse to one: "Secrets, Secrets" is a leak of how many scanners ran.
categories_display() { # comma-separated wire values -> display label
  local out="" seen="" c d
  IFS=',' read -ra _cats <<< "${1:-}"
  for c in "${_cats[@]:-}"; do
    [ -n "$c" ] || continue
    d="$(category_display "$c")"
    case ",$seen," in *",$d,"*) continue ;; esac
    seen="${seen:+$seen,}$d"
    out="${out:+$out, }$d"
  done
  [ -n "$out" ] || out="$(category_display "")"
  printf '%s' "$out"
}

# --- fetch the scan tool catalogue ----------------------------------------
# The selection set is assembled from the fields the schema actually has, not
# from the fields it had when this was written. `DockerScanTool.name` is on its
# way out, because no scanner identity reaches a client any more, and
# `.categories` is on its way in. A `scan-tools` value is pinned in a consumer's
# own workflow file and outlives both changes.
#
# This matters more than it looks: selecting a field the schema has dropped
# fails the *whole* query with GRAPHQL_VALIDATION_FAILED, so a run that asked
# for a tool by id fails exactly as hard as one that asked by name, and the
# annotation blames the caller's input for a change made on our side. Narrow the
# selection from the validation error and retry instead.
_TOOL_OPTIONAL_FIELDS="name categories"
scan_tool_catalogue() {
  local optional="$_TOOL_OPTIONAL_FIELDS" sel resp keep f attempt=0
  while :; do
    attempt=$(( attempt + 1 ))
    sel="id${optional:+ $optional}"
    resp="$(gql_post "$(jq -n --arg q "{dockerScanTools(list:{}){items{$sel}}}" '{query:$q}')")"
    if ! echo "$resp" | jq -e '.errors' >/dev/null 2>&1; then
      echo "$resp" | jq '.data'
      return 0
    fi
    keep=""
    for f in $optional; do
      if echo "$resp" | jq -e --arg f "$f" \
        '[.errors[].message] | any(test("Cannot query field \"" + $f + "\""))' >/dev/null 2>&1; then
        continue
      fi
      keep="${keep:+$keep }$f"
    done
    # Only a rejected optional field is recoverable. Anything else is a real
    # error and has to surface with the gateway's own wording.
    if [ "$keep" = "$optional" ] || [ "$attempt" -ge 3 ]; then
      gql_errors "$resp"
      fail "GraphQL request failed"
    fi
    optional="$keep"
  done
}

# --- resolve scan tools (by id, or by name while the gateway still has one) --
# Echoes "id<TAB>category label" per line. No scanner identity leaves this
# function: the caller is handed a category label and has nothing else to print.
resolve_tools() {
  local data; data="$(scan_tool_catalogue)"
  local by_name
  by_name="$(echo "$data" | jq -r 'if [(.dockerScanTools.items // [])[] | has("name")] | any then "yes" else "no" end')"
  local found=0
  IFS=',' read -ra wanted <<< "$SCAN_TOOLS"
  for raw in "${wanted[@]}"; do
    local t; t="$(echo "$raw" | sed 's/^ *//;s/ *$//')"
    [ -n "$t" ] || continue
    local pair
    pair="$(echo "$data" | jq -r --arg t "$t" --arg byname "$by_name" \
      '[.dockerScanTools.items[]
         | select(.id == $t or ($byname == "yes" and ((.name // "") | ascii_downcase) == ($t | ascii_downcase)))][0]
       | select(.) | "\(.id)\t\((.categories // []) | join(","))"')"
    if [ -z "$pair" ]; then
      if [ "$by_name" = "no" ] && ! looks_like_id "$t"; then
        fail "scan tool '$t' is not a scan tool id, and this Vulnara gateway no longer resolves scan tools by name. Open $APP_URL, copy the id shown against the scanner you want, and use that in scan-tools."
      fi
      fail "scan tool '$t' is not available to tenant '$TENANT'. Open $APP_URL to see the scanners this workspace can run, and pass the id shown there."
    fi
    printf '%s\t%s\n' "${pair%%$'\t'*}" "$(categories_display "${pair#*$'\t'}")"
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
declare -a TOOL_IDS=() TOOL_CATEGORIES=()
# resolve_tools is captured into a variable rather than consumed through a process
# substitution: a `fail` inside `< <(...)` would only kill the subshell and let the
# run continue with an empty tool list and exit 0.
TOOL_LIST="$(resolve_tools)" || exit 1
while IFS=$'\t' read -r tid tlabel; do
  [ -n "$tid" ] || continue
  TOOL_IDS+=("$tid"); TOOL_CATEGORIES+=("$tlabel")
  info "category" "$tlabel ($tid)"
done <<< "$TOOL_LIST"
ok "${#TOOL_IDS[@]} scan tool(s) selected"

# --- [4/5] start + wait for scans ------------------------------------------
step 4 "Run scans on branch '$BRANCH'"
declare -a SCANS=() SCAN_CATEGORIES=() SCAN_DURATIONS=()
SCAN_IDS=""
for i in "${!TOOL_IDS[@]}"; do
  label="${TOOL_CATEGORIES[$i]}"
  srid="$(start_scan "${TOOL_IDS[$i]}")"
  [ -n "$srid" ] || fail "scan did not return a scan result id (tool '$label')"
  SCANS+=("$srid"); SCAN_CATEGORIES+=("$label")
  SCAN_IDS="$SCAN_IDS $srid"
  ok "started '$label' -> scan $srid"
done
SCAN_IDS="$(echo "$SCAN_IDS" | sed 's/^ *//')"

log "waiting for ${#SCANS[@]} scan(s) to finish (timeout ${WAIT_TIMEOUT}s, polling every ${POLL_INTERVAL}s)"
for i in "${!SCANS[@]}"; do
  dur="$(wait_scan "${SCANS[$i]}" "${SCAN_CATEGORIES[$i]}")"
  SCAN_DURATIONS+=("$dur")
  ok "${SCAN_CATEGORIES[$i]} completed in ${dur}s"
done

# --- [5/5] collect findings + gate -----------------------------------------
step 5 "Evaluate findings"
HIGHEST=0; HIGHEST_NAME="NONE"
declare -A SEV_TOTAL=( [CRITICAL]=0 [HIGH]=0 [MEDIUM]=0 [LOW]=0 )
declare -a SCAN_FINDINGS=() SCAN_ITEMS=()
for srid in "${SCANS[@]}"; do
  data="$(gql "$(jq -n --arg id "$srid" \
    '{query:"query($l:List){scanFindings(list:$l){items{id severity file line confidence commitScan{commitHash}}}}",variables:{l:{filters:[{field:"scanResultId",stringEquals:$id}]}}}')")"
  items="$(echo "$data" | jq -c '.scanFindings.items // []')"
  SCAN_ITEMS+=("$items")
  cnt=0
  while read -r sev; do
    [ -n "$sev" ] || continue
    cnt=$(( cnt + 1 ))
    up="$(echo "$sev" | tr '[:lower:]' '[:upper:]')"
    case "$up" in CRITICAL|HIGH|MEDIUM|LOW) SEV_TOTAL[$up]=$(( ${SEV_TOTAL[$up]:-0} + 1 )) ;; esac
    r="$(sev_rank "$up")"
    if [ "$r" -gt "$HIGHEST" ]; then HIGHEST="$r"; HIGHEST_NAME="$up"; fi
  done < <(echo "$items" | jq -r '.[].severity')
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
for i in "${!SCANS[@]}"; do
  info "view scan" "${SCAN_CATEGORIES[$i]}: ${APP_URL}/repository-scans/${SCANS[$i]}"
done

# combine all findings, tagging each with its scan's category, for the table
ALL_ITEMS="[]"
for i in "${!SCANS[@]}"; do
  ALL_ITEMS="$(jq -c --argjson acc "$ALL_ITEMS" --arg category "${SCAN_CATEGORIES[$i]}" \
    '$acc + (map(. + {category:$category}))' <<<"${SCAN_ITEMS[$i]}")"
done

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
    echo "| Category | Duration | Findings | View in Vulnara |"
    echo "|---|---|---|---|"
    for i in "${!SCANS[@]}"; do
      echo "| ${SCAN_CATEGORIES[$i]} | ${SCAN_DURATIONS[$i]:-?}s | ${SCAN_FINDINGS[$i]:-0} | [\`${SCANS[$i]:0:8}\`]($APP_URL/repository-scans/${SCANS[$i]}) |"
    done
    if [ "$TOTAL" -gt 0 ]; then
      echo ""
      echo "### Detailed findings"
      echo ""
      shown="$(echo "$ALL_ITEMS" | jq -r '[.[] | select((.file // "") != "")] | length')"
      echo "| Severity | Location | Category | Confidence |"
      echo "|---|---|---|---|"
      echo "$ALL_ITEMS" | jq -r --arg base "$REPO_URL" --arg prov "$REPO_PROVIDER" --argjson limit "$FINDING_LIMIT" '
        def rank(s): (s // "" | ascii_upcase) as $u
          | if $u=="CRITICAL" then 4 elif $u=="HIGH" then 3 elif $u=="MEDIUM" then 2 elif $u=="LOW" then 1 else 0 end;
        def sevlabel(s): (s // "" | ascii_upcase) as $u
          | if $u=="CRITICAL" then "Critical" elif $u=="HIGH" then "High" elif $u=="MEDIUM" then "Medium" elif $u=="LOW" then "Low" else (s // "-") end;
        def loc:
          if (.file // "") == "" then "-"
          else (.file + (if .line == null then "" else ":" + (.line|tostring) end)) as $txt
            | if ($base == "") or ((.commitScan.commitHash // "") == "") then $txt
              else (.commitScan.commitHash) as $sha | (.line|tostring) as $n
                | (if $prov=="gitlab" then $base + "/-/blob/" + $sha + "/" + .file + (if .line==null then "" else "#L"+$n end)
                   elif $prov=="bitbucket" then $base + "/src/" + $sha + "/" + .file + (if .line==null then "" else "#lines-"+$n end)
                   elif $prov=="azure_devops" then $base + "?path=/" + .file + "&version=GC" + $sha
                     + (if .line==null then "" else "&line="+$n+"&lineEnd="+$n+"&lineStartColumn=1&lineEndColumn=1" end)
                   elif $prov=="forgejo" then $base + "/src/commit/" + $sha + "/" + .file + (if .line==null then "" else "#L"+$n end)
                   else $base + "/blob/" + $sha + "/" + .file + (if .line==null then "" else "#L"+$n end)
                   end) as $u
                | "[`" + $txt + "`](" + $u + ")"
              end
          end;
        [.[] | select((.file // "") != "")]
        | sort_by(-rank(.severity))
        | .[:$limit]
        | .[] | "| " + sevlabel(.severity) + " | " + loc + " | " + (.category // "-") + " | " + (.confidence // "-") + " |"'
      if [ "$shown" -gt "$FINDING_LIMIT" ]; then
        echo ""
        echo "_Showing the top $FINDING_LIMIT of $shown located findings. Open the scans above to see all._"
      fi
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

hr
log "findings -> critical=${SEV_TOTAL[CRITICAL]} high=${SEV_TOTAL[HIGH]} medium=${SEV_TOTAL[MEDIUM]} low=${SEV_TOTAL[LOW]} (total $TOTAL) in ${RUN_TIME}s"
if [ "$PASSED" = "false" ]; then
  fail "scan gate failed: highest severity '$HIGHEST_LABEL' meets/exceeds fail-on '$FAIL_ON'"
fi
log "✓ scan gate passed (fail-on: $FAIL_ON, highest: $HIGHEST_LABEL)"
hr
