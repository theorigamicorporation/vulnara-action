#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Vulnara Scan action. Authenticate a service account (OAuth client_credentials
# -> JWT), resolve the repository, start a scan per tool on the branch, wait for
# them to finish, and gate the build on the highest finding severity. Talks to
# the Vulnara GraphQL gateway directly (curl + jq).
# ---------------------------------------------------------------------------

log()  { echo "vulnara: $*" >&2; }
fail() {
  case "$CI_PLATFORM" in
    github) echo "::error::$*" >&2 ;;
    *)      echo "ERROR: $*" >&2 ;;
  esac
  exit 1
}

# --- console polish -------------------------------------------------------
STEP_TOTAL=5
step()     { echo "" >&2; echo "vulnara: [$1/${STEP_TOTAL}] $2" >&2; }
info()     { printf 'vulnara:   %-12s %s\n' "$1" "$2" >&2; }
ok()       { echo "vulnara:   ✓ $*" >&2; }
warn() {
  case "$CI_PLATFORM" in
    github) echo "::warning::$*" >&2 ;;
    *)      echo "WARNING: $*" >&2 ;;
  esac
}
GROUP_N=0; GROUP_ID=""
group() {
  case "$CI_PLATFORM" in
    github) echo "::group::$*" >&2 ;;
    gitlab) GROUP_N=$(( GROUP_N + 1 )); GROUP_ID="vulnara_$GROUP_N"
            printf '\e[0Ksection_start:%s:%s[collapsed=true]\r\e[0K%s\n' "$(date +%s)" "$GROUP_ID" "$*" >&2 ;;
    *)      echo "$*" >&2 ;;
  esac
}
endgroup() {
  case "$CI_PLATFORM" in
    github) echo "::endgroup::" >&2 ;;
    gitlab) printf '\e[0Ksection_end:%s:%s\r\e[0K\n' "$(date +%s)" "$GROUP_ID" >&2 ;;
  esac
}
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

# --- CI platform ------------------------------------------------------------
# Decided before any other input, because it picks where defaults, annotations,
# outputs and the summary come from and go to. An invalid override is reported in
# the detected platform's syntax.
detect_platform() {
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then echo github
  elif [ "${GITLAB_CI:-}" = "true" ]; then echo gitlab
  else echo none; fi
}
CI_PLATFORM="$(detect_platform)"
REQUESTED_PLATFORM="$(input ci-platform | tr '[:upper:]' '[:lower:]')"
case "$REQUESTED_PLATFORM" in
  "") ;;
  github|gitlab|none) CI_PLATFORM="$REQUESTED_PLATFORM" ;;
  *) fail "invalid ci-platform '$REQUESTED_PLATFORM' (expected github|gitlab|none)" ;;
esac

default_branch() {
  case "$CI_PLATFORM" in
    github) printf '%s' "${GITHUB_REF_NAME:-}" ;;
    gitlab) printf '%s' "${CI_MERGE_REQUEST_SOURCE_BRANCH_NAME:-${CI_COMMIT_BRANCH:-}}" ;;
  esac
}
default_repository() {
  case "$CI_PLATFORM" in
    github) printf '%s' "${GITHUB_REPOSITORY:-}" ;;
    gitlab) printf '%s' "${CI_PROJECT_PATH:-}" ;;
  esac
}

REPORT_DIR="$(input report-dir)"
if [ -z "$REPORT_DIR" ] && [ "$CI_PLATFORM" = "gitlab" ] && [ -n "${CI_PROJECT_DIR:-}" ]; then
  REPORT_DIR="$CI_PROJECT_DIR/.vulnara"
fi

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
BRANCH="$(input branch)";         [ -n "$BRANCH" ]     || BRANCH="$(default_branch)"
REPOSITORY="$(input repository)";  [ -n "$REPOSITORY" ] || REPOSITORY="$(default_repository)"
GIT_TOKEN_ID="$(input git-token-id)"
FAIL_ON="$(input fail-on | tr '[:upper:]' '[:lower:]')"; [ -n "$FAIL_ON" ] || FAIL_ON="critical"
CREATE_ISSUE="$(input create-issue)";     [ -n "$CREATE_ISSUE" ]   || CREATE_ISSUE="false"
AUTO_REMEDIATE="$(input auto-remediate)"; [ -n "$AUTO_REMEDIATE" ] || AUTO_REMEDIATE="false"
WAIT_TIMEOUT="$(input wait-timeout)";     [ -n "$WAIT_TIMEOUT" ]   || WAIT_TIMEOUT="1800"
POLL_INTERVAL="$(input poll-interval)";   [ -n "$POLL_INTERVAL" ]  || POLL_INTERVAL="15"

WEB_TARGET_ID="$(input web-target-id | sed 's/^ *//;s/ *$//')"
WEB_URL="$(input web-url | sed 's/^ *//;s/ *$//')"
WEB_CONSENT="$(input web-ownership-consent)"

# A run scans a repository (scan-tools), a web target (web-target-id or
# web-url), or both. Neither is the old "scan-tools is required".
REPO_SCAN="false"; [ -z "$SCAN_TOOLS" ] || REPO_SCAN="true"
WEB_SCAN="false";  if [ -n "$WEB_TARGET_ID" ] || [ -n "$WEB_URL" ]; then WEB_SCAN="true"; fi

[ -n "$SERVICE_ACCOUNT" ] || fail "service-account is required"
[ -n "$TOKEN" ]           || fail "token is required"
[ -n "$TENANT" ]          || fail "tenant is required"
if [ "$REPO_SCAN" = "false" ] && [ "$WEB_SCAN" = "false" ]; then fail "scan-tools is required"; fi
if [ "$REPO_SCAN" = "true" ]; then
  [ -n "$REPOSITORY" ]    || fail "repository could not be determined"
  [ -n "$BRANCH" ]        || fail "branch could not be determined"
fi

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

# --- web application inputs (validated before any network call) ----------
# web-url may register the URL as a scan target, and registering one is an
# attestation that the caller owns it or is authorised to scan it. The action
# never makes that attestation on the caller's behalf: web-url is refused unless
# the workflow says web-ownership-consent: true, literally. web-target-id names a
# target someone already registered, attestation on file, so it needs nothing.
validate_web_inputs() {
  [ "$WEB_SCAN" = "true" ] || return 0
  if [ -n "$WEB_TARGET_ID" ] && [ -n "$WEB_URL" ]; then
    fail "set web-target-id or web-url, not both: one run scans one web target"
  fi
  if [ -n "$WEB_TARGET_ID" ]; then
    looks_like_id "$WEB_TARGET_ID" \
      || fail "web-target-id '$WEB_TARGET_ID' is not a web target id. Copy the id from the web target in Vulnara, or pass web-url instead."
    return 0
  fi
  local authority="${WEB_URL#*://}"; authority="${authority%%[/?#]*}"
  # Checked before anything else about the URL, and the URL is never echoed:
  # the log is world-readable on a public repository.
  case "$authority" in *@*) fail "web-url must not carry credentials (user:password@); pass the bare URL of the application" ;; esac
  if ! [[ "$WEB_URL" =~ ^[Hh][Tt][Tt][Pp][Ss]?://[^/?#[:space:]]+([/?#][^[:space:]]*)?$ ]]; then
    fail "web-url '$WEB_URL' is not an http(s) URL"
  fi
  if [ "$WEB_CONSENT" != "true" ]; then
    fail "web-url requires web-ownership-consent: true. Scanning '$WEB_URL' may register it as a web target in Vulnara, which records that you own it or are authorised to scan it. Set web-ownership-consent: 'true' to confirm, or pass the id of an existing target as web-target-id."
  fi
}

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
REPO_QUERY='query($l:List){repositories(list:$l){total items{id repositoryName private enabled programmingLanguage cloneUrl gitEntity{__typename ... on Organization{name gitType htmlUrl} ... on GitUser{name gitType htmlUrl}}}}}'
resolve_repository() {
  local owner="${REPOSITORY%%/*}" name="${REPOSITORY##*/}" rest="${REPOSITORY#*/}" data item azure count
  local lowner; lowner="$(echo "$owner" | tr '[:upper:]' '[:lower:]')"
  # A GitLab subgroup project is stored under the entity "group/sub", so the
  # non-Azure owner is everything before the last segment.
  local lnamespace; lnamespace="$(echo "${REPOSITORY%/*}" | tr '[:upper:]' '[:lower:]')"
  local provider=""; [ "$CI_PLATFORM" = "none" ] || provider="$CI_PLATFORM"
  data="$(gql "$(jq -n --arg q "$REPO_QUERY" --arg n "$name" \
    '{query:$q, variables:{l:{filters:[{field:"repositoryName",stringEquals:$n}]}}}')")"
  item="$(echo "$data" | jq -c --arg o "$lnamespace" --arg p "$provider" \
    '[.repositories.items[] | select(.gitEntity.gitType != "azure_devops")
       | select(((.gitEntity.name // "") | ascii_downcase) == $o)] as $c
     | ([$c[] | select(.gitEntity.gitType == $p)][0] // $c[0]) // empty')"
  if [ -z "$item" ]; then
    # Azure stores "{project}/{repo}" under the org entity, so the name filter above never finds it.
    azure="$(gql "$(jq -n --arg q "$REPO_QUERY" --arg s "$name" \
      '{query:$q, variables:{l:{search:$s, limit:500}}}')")"
    [ "$(echo "$azure" | jq '.repositories.total > (.repositories.items | length)')" = "false" ] \
      || fail "too many repositories match '$name' in Vulnara (tenant '$TENANT') to resolve '$REPOSITORY' safely."
    azure="$(echo "$azure" | jq -c --arg o "$lowner" --arg r "$rest" --arg full "$REPOSITORY" --arg n "$name" \
      '[.repositories.items[] | select(.gitEntity.gitType == "azure_devops")
        | ((.gitEntity.name // "") | ascii_downcase) as $e
        | select(if ($r | contains("/"))
                 then .repositoryName == $r and $e == $o
                 else .repositoryName == $full or ($e == $o and (.repositoryName | split("/") | last) == $n)
                 end)]')"
    count="$(echo "$azure" | jq 'length')"
    if [ "$count" -gt 1 ]; then
      fail "repository '$REPOSITORY' is ambiguous in Vulnara (tenant '$TENANT'): $(echo "$azure" | jq -r '[.[] | "\(.gitEntity.name)/\(.repositoryName)"] | join(", ")'). Pass the full org/project/repo."
    fi
    item="$(echo "$azure" | jq -c '.[0] // empty')"
    [ -n "$item" ] || item="$(echo "$data" | jq -c '.repositories.items[0] // empty')"
  fi
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
# `dast` is named ahead of any scanner serving it (OpenProject #1292), so the
# first scan that covers it is not labelled `Uncategorised`.
category_display() {
  case "$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    sast)    printf 'Code analysis' ;;
    sca)     printf 'Dependencies' ;;
    secrets) printf 'Secrets' ;;
    pii)     printf 'Personal data' ;;
    dast)    printf 'Web application' ;;
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
# `DockerScanTool.name` is not selected, and not optional: it is gone from the
# gateway, and asking for it would fail the whole query with
# GRAPHQL_VALIDATION_FAILED before any id was matched. Nothing here would print
# it if it came back, either, so there is no version of this action that wants a
# scanner name.
#
# `.categories` is still narrowable. `gateway-url` is an action input, so a
# non-prod or self-hosted gateway predating that field is a real deployment, and
# selecting it unconditionally would turn "labelled Uncategorised" into "the run
# fails and starts no scan" for a tool id pinned in a workflow file we do not
# control. Narrow the selection from the validation error and retry instead.
_TOOL_OPTIONAL_FIELDS="categories"
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

# --- resolve scan tools, by id --------------------------------------------
# Echoes "id<TAB>category label" per line. No scanner identity enters this
# function, let alone leaves it: the catalogue carries ids and categories, and
# the caller is handed a category label and has nothing else it could print.
#
# `scan-tools` takes ids only. It used to accept a stored name as well, which
# worked because the gateway returned one; it does not, so a name cannot be
# matched against anything and the failure has to say that rather than blame the
# tenant's availability. A category label is not accepted here either: a
# category scan is one request that fans out server-side, which is
# startRepositoryCategoryScan, not N of these.
# Where a tool id comes from. The Vulnara application has no screen listing
# scanner ids, so the hint names the two places that do: vulnara-cli's
# docker_scan_tools command and the dockerScanTools query it runs. Both list ids
# and categories only, never a scanner's name.
TOOL_ID_HINT="List the ids this workspace can run with 'vulnara docker_scan_tools' (vulnara-cli) or the GraphQL query 'dockerScanTools { id categories }', and pass one of those."
resolve_tools() {
  local raw t found=0
  IFS=',' read -ra wanted <<< "$SCAN_TOOLS"
  # Shape first, and before the catalogue is fetched: whether an entry is an id
  # is knowable without asking the gateway, and a typo should not cost a request
  # or borrow the catalogue's wording.
  for raw in "${wanted[@]}"; do
    t="$(echo "$raw" | sed 's/^ *//;s/ *$//')"
    [ -n "$t" ] || continue
    looks_like_id "$t" && continue
    fail "scan tool '$t' is not a scan tool id. scan-tools takes ids: this Vulnara gateway does not resolve scanners by name, and a category label belongs to a category scan rather than to scan-tools. $TOOL_ID_HINT"
  done
  local data; data="$(scan_tool_catalogue)"
  for raw in "${wanted[@]}"; do
    t="$(echo "$raw" | sed 's/^ *//;s/ *$//')"
    [ -n "$t" ] || continue
    local pair
    pair="$(echo "$data" | jq -r --arg t "$t" \
      '[.dockerScanTools.items[] | select(.id == $t)][0]
       | select(.) | "\(.id)\t\((.categories // []) | join(","))"')"
    if [ -z "$pair" ]; then
      fail "scan tool '$t' is not available to tenant '$TENANT'. $TOOL_ID_HINT"
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

# A value safe inside a Markdown table cell: one line, pipes escaped.
md_cell() { printf '%s' "${1:-}" | tr '\r\n' '  ' | sed 's/|/\\|/g'; }

sev_label() {
  case "$1" in CRITICAL) echo "Critical";; HIGH) echo "High";; MEDIUM) echo "Medium";; LOW) echo "Low";; *) echo "none";; esac
}

# --- web application scanning ----------------------------------------------
# One web target per run, scanned alongside (or instead of) the repository. The
# scan is labelled `Web application` everywhere; nothing here selects, let alone
# prints, what runs it.
WEB_LABEL="Web application"
WEB_NOT_ENABLED="web application scanning is not enabled for workspace '$TENANT'. Ask your Vulnara administrator to enable it, or remove web-target-id/web-url from this workflow."
WEB_TARGET_NAME=""; WEB_TARGET_URL=""; WEB_TARGET_CREATED="false"

# The first GraphQL error code in a response, or empty.
gql_code() { echo "$1" | jq -r '[.errors[]? | .extensions.code // empty][0] // empty' 2>/dev/null || true; }
has_errors() { echo "$1" | jq -e '.errors' >/dev/null 2>&1; }

# Fail on a web request's errors with a message saying what the code means,
# then the gateway's own lines beneath it.
web_fail() { # response context
  local resp="$1" ctx="$2" code msg
  code="$(gql_code "$resp")"
  case "$code" in
    NO_SCANNER_FOR_CATEGORY) msg="$WEB_NOT_ENABLED" ;;
    *LIMIT_EXCEEDED) msg="$ctx: the workspace's plan limit for web application scanning is reached ($code). Wait for running scans to finish, remove unused web targets, or raise the plan." ;;
    WEB_TARGET_ADDRESS_REFUSED) msg="$ctx: the web target does not resolve to public addresses only. Only publicly reachable applications can be scanned." ;;
    NOT_FOUND|WEB_TARGET_NOT_FOUND) msg="$ctx: web target not found in workspace '$TENANT'. Check web-target-id, or that the service account belongs to the workspace that owns it." ;;
    VALIDATION_ERROR) msg="$ctx: the gateway rejected the request: $(echo "$resp" | jq -r '[.errors[].extensions.fields[]? | "\(.field): \(.message // .code)"] | join("; ") | if . == "" then "invalid input" else . end')" ;;
    *) msg="$ctx failed" ;;
  esac
  gql_errors "$resp"
  fail "$msg"
}

# A comparison key for a base URL: scheme and host lowercased, trailing host dot
# dropped, an empty path read as "/", the fragment dropped. The subset of the
# platform's own normalisation that decides whether two URLs are one target.
JQ_URL_KEY='def urlkey: (capture("^(?<s>[A-Za-z][A-Za-z0-9+.-]*)://(?<a>[^/?#]*)(?<r>[^#]*)") // {s:"",a:.,r:""})
  | (.a | ascii_downcase | sub("\\.(?<p>:[0-9]+)?$"; "\(.p // "")")) as $a
  | (if .r == "" then "/" elif (.r | startswith("?")) then "/" + .r else .r end) as $r
  | (.s | ascii_downcase) + "://" + $a + $r;'

web_url_host() { # the host the platform stores for a URL: lowercased, no port, no trailing dot
  local a="${1#*://}"; a="${a%%[/?#]*}"
  if [[ "$a" == \[* ]]; then a="${a#\[}"; a="${a%%\]*}"; else a="${a%%:*}"; fi
  a="${a%.}"
  printf '%s' "$a" | tr '[:upper:]' '[:lower:]'
}

# Fail closed: a workspace that may not run web scans must not get a target
# registered on its behalf first. startWebScan stays the authority (its
# NO_SCANNER_FOR_CATEGORY maps to the same message); this only answers earlier.
check_web_scanning_enabled() {
  local data
  data="$(gql '{"query":"{scanCategories}"}')"
  echo "$data" | jq -e '(.scanCategories // []) | map(ascii_upcase) | index("DAST")' >/dev/null 2>&1 \
    || fail "$WEB_NOT_ENABLED"
}

# Sets WEB_TARGET_ID, WEB_TARGET_NAME, WEB_TARGET_URL, WEB_TARGET_CREATED.
resolve_web_target() {
  local resp item
  if [ -n "$WEB_TARGET_ID" ]; then
    resp="$(gql_post "$(jq -n --arg id "$WEB_TARGET_ID" \
      '{query:"query($id:ID!){webTarget(id:$id){id name baseUrl}}",variables:{id:$id}}')")"
    if has_errors "$resp"; then web_fail "$resp" "web-target-id '$WEB_TARGET_ID'"; fi
    item="$(echo "$resp" | jq -c '.data.webTarget // empty')"
    [ -n "$item" ] || fail "web-target-id '$WEB_TARGET_ID': web target not found in workspace '$TENANT'."
  else
    local host want matches count
    host="$(web_url_host "$WEB_URL")"
    want="$(jq -rn --arg u "$WEB_URL" "$JQ_URL_KEY"' $u | urlkey')"
    resp="$(gql "$(jq -n --arg h "$host" \
      '{query:"query($l:List){webTargets(list:$l){total items{id name baseUrl}}}",variables:{l:{filters:[{field:"host",stringEquals:$h}],limit:500}}}')")"
    matches="$(echo "$resp" | jq -c --arg want "$want" "$JQ_URL_KEY"' [.webTargets.items[] | select((.baseUrl | urlkey) == $want)]')"
    count="$(echo "$matches" | jq 'length')"
    if [ "$count" -gt 1 ]; then
      fail "web-url '$WEB_URL' matches $count web targets in workspace '$TENANT' ($(echo "$matches" | jq -r 'map(.id) | join(", ")')). Pass the one to scan as web-target-id."
    fi
    item="$(echo "$matches" | jq -c '.[0] // empty')"
    if [ -z "$item" ]; then
      local input
      input="$(jq -n --arg u "$WEB_URL" '{name:($u[0:255]), baseUrl:$u, ownershipConsent:true}')"
      resp="$(gql_post "$(jq -n --argjson i "$input" \
        '{query:"mutation($i:CreateWebTargetInput!){createWebTarget(input:$i){id name baseUrl}}",variables:{i:$i}}')")"
      if has_errors "$resp"; then web_fail "$resp" "registering web-url '$WEB_URL'"; fi
      item="$(echo "$resp" | jq -c '.data.createWebTarget // empty')"
      [ -n "$item" ] || fail "registering web-url '$WEB_URL' returned no web target"
      WEB_TARGET_CREATED="true"
    fi
  fi
  WEB_TARGET_ID="$(echo "$item" | jq -r '.id')"
  WEB_TARGET_NAME="$(echo "$item" | jq -r '.name // "?"')"
  WEB_TARGET_URL="$(echo "$item" | jq -r '.baseUrl // ""')"
}

start_web_scan() { # echo the web scan result id
  local resp
  resp="$(gql_post "$(jq -n --arg t "$WEB_TARGET_ID" \
    '{query:"mutation($i:StartWebScanInput!){startWebScan(input:$i){id webScanResult{id status}}}",variables:{i:{webTargetId:$t}}}')")"
  if has_errors "$resp"; then web_fail "$resp" "starting the web application scan"; fi
  echo "$resp" | jq -r '.data.startWebScan.webScanResult.id // empty'
}

# The same contract as wait_scan, against webScanResult.
wait_web_scan() {
  local srid="$1" start; start="$(date +%s)"
  local deadline=$(( start + WAIT_TIMEOUT )) status last=""
  while :; do
    status="$(gql "$(jq -n --arg id "$srid" '{query:"query($id:ID!){webScanResult(id:$id){status}}",variables:{id:$id}}')" \
      | jq -r '.webScanResult.status // "PENDING"')"
    local now; now="$(date +%s)"
    case "$(echo "$status" | tr '[:lower:]' '[:upper:]')" in
      SUCCESS) echo $(( now - start )); return 0 ;;
      FAILED|CANCELLED) fail "scan for '$WEB_LABEL' ended as $status (id $srid)" ;;
    esac
    if [ "$status" != "$last" ]; then info "$WEB_LABEL" "$status ($(( now - start ))s elapsed)"; last="$status"; fi
    [ "$now" -lt "$deadline" ] || fail "timed out after ${WAIT_TIMEOUT}s waiting for '$WEB_LABEL' (still $status, id $srid)"
    sleep "$POLL_INTERVAL"
  done
}

# Exact per-severity counts from each filtered list's total: no paging, and the
# gate never decides on a partial page.
web_finding_counts() { # srid -> {"CRITICAL":n,...}
  local srid="$1" q
  q='query WebFindingCounts($c:List,$h:List,$m:List,$l:List){c:dastFindings(list:$c){total} h:dastFindings(list:$h){total} m:dastFindings(list:$m){total} l:dastFindings(list:$l){total}}'
  gql "$(jq -n --arg q "$q" --arg id "$srid" '
    def f(s): {limit:1, filters:[{field:"scanResultId",stringEquals:$id},{field:"severity",stringEquals:s}]};
    {query:$q, variables:{c:f("CRITICAL"), h:f("HIGH"), m:f("MEDIUM"), l:f("LOW")}}')" \
    | jq -c '{CRITICAL:(.c.total // 0), HIGH:(.h.total // 0), MEDIUM:(.m.total // 0), LOW:(.l.total // 0)}'
}

web_finding_items() { # srid -> the top FINDING_LIMIT ranked findings, most severe first
  local srid="$1" q
  q='query WebFindingItems($c:List,$h:List,$m:List,$l:List){c:dastFindings(list:$c){items{...F}} h:dastFindings(list:$h){items{...F}} m:dastFindings(list:$m){items{...F}} l:dastFindings(list:$l){items{...F}}} fragment F on DastFinding{id templateId name severity matchedAt cveIds cweIds}'
  gql "$(jq -n --arg q "$q" --arg id "$srid" --argjson n "$FINDING_LIMIT" '
    def f(s): {limit:$n, filters:[{field:"scanResultId",stringEquals:$id},{field:"severity",stringEquals:s}]};
    {query:$q, variables:{c:f("CRITICAL"), h:f("HIGH"), m:f("MEDIUM"), l:f("LOW")}}')" \
    | jq -c --argjson n "$FINDING_LIMIT" '(.c.items // []) + (.h.items // []) + (.m.items // []) + (.l.items // []) | .[:$n]'
}

# ===========================================================================
validate_web_inputs

# Steps are numbered for the run that is actually happening: a repository run
# keeps its five, a web-only run has four, a run doing both has six.
STEP_TOTAL=3
[ "$REPO_SCAN" = "false" ] || STEP_TOTAL=$(( STEP_TOTAL + 2 ))
[ "$WEB_SCAN" = "false" ]  || STEP_TOTAL=$(( STEP_TOTAL + 1 ))
STEP_N=0
next_step() { STEP_N=$(( STEP_N + 1 )); step "$STEP_N" "$1"; }

RUN_START="$(date +%s)"
hr
log "Vulnara security scan"
log "CI platform: $CI_PLATFORM"
hr

# --- authenticate -----------------------------------------------------------
next_step "Authenticate service account"
ensure_jwt
ok "authenticated as '$SERVICE_ACCOUNT' (tenant '$TENANT'), token valid ~${JWT_TTL}s"

declare -a TOOL_IDS=() TOOL_CATEGORIES=()
if [ "$REPO_SCAN" = "true" ]; then
# --- resolve repository -----------------------------------------------------
next_step "Resolve repository in Vulnara"
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

# --- resolve scan tools -----------------------------------------------------
next_step "Resolve scan tools"
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
fi

# --- resolve the web target --------------------------------------------------
if [ "$WEB_SCAN" = "true" ]; then
  next_step "Resolve web target"
  check_web_scanning_enabled
  resolve_web_target
  info "Web target" "$WEB_TARGET_NAME"
  info "URL" "$WEB_TARGET_URL"
  info "Vulnara id" "$WEB_TARGET_ID"
  if [ "$WEB_TARGET_CREATED" = "true" ]; then
    ok "registered '$WEB_TARGET_URL' as a web target (ownership consent given by the workflow)"
  else
    ok "resolved web target '$WEB_TARGET_NAME'"
  fi
fi

# --- start + wait for scans ----------------------------------------------------
if [ "$REPO_SCAN" = "true" ]; then next_step "Run scans on branch '$BRANCH'"; else next_step "Run scans"; fi
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

# Started after the repository scans so both kinds run concurrently on the
# platform; waited on after them, in its own wait-timeout window like each one.
WEB_SRID=""; WEB_DURATION=""
if [ "$WEB_SCAN" = "true" ]; then
  WEB_SRID="$(start_web_scan)" || exit 1
  [ -n "$WEB_SRID" ] || fail "the web application scan did not return a scan result id"
  ok "started '$WEB_LABEL' -> scan $WEB_SRID"
fi

SCAN_COUNT=${#SCANS[@]}; [ -z "$WEB_SRID" ] || SCAN_COUNT=$(( SCAN_COUNT + 1 ))
log "waiting for ${SCAN_COUNT} scan(s) to finish (timeout ${WAIT_TIMEOUT}s, polling every ${POLL_INTERVAL}s)"
for i in "${!SCANS[@]}"; do
  dur="$(wait_scan "${SCANS[$i]}" "${SCAN_CATEGORIES[$i]}")"
  SCAN_DURATIONS+=("$dur")
  ok "${SCAN_CATEGORIES[$i]} completed in ${dur}s"
done
if [ -n "$WEB_SRID" ]; then
  WEB_DURATION="$(wait_web_scan "$WEB_SRID")"
  ok "$WEB_LABEL completed in ${WEB_DURATION}s"
fi

# --- collect findings + gate ---------------------------------------------------
next_step "Evaluate findings"
HIGHEST=0; HIGHEST_NAME="NONE"
declare -A SEV_TOTAL=( [CRITICAL]=0 [HIGH]=0 [MEDIUM]=0 [LOW]=0 )
declare -a SCAN_FINDINGS=() SCAN_ITEMS=()
for srid in "${SCANS[@]:-}"; do
  [ -n "$srid" ] || continue
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

WEB_COUNTS='{"CRITICAL":0,"HIGH":0,"MEDIUM":0,"LOW":0}'; WEB_ITEMS="[]"; WEB_TOTAL=0
if [ -n "$WEB_SRID" ]; then
  WEB_COUNTS="$(web_finding_counts "$WEB_SRID")"
  for up in CRITICAL HIGH MEDIUM LOW; do
    n="$(echo "$WEB_COUNTS" | jq -r --arg s "$up" '.[$s] // 0')"
    SEV_TOTAL[$up]=$(( ${SEV_TOTAL[$up]:-0} + n ))
    WEB_TOTAL=$(( WEB_TOTAL + n ))
    r="$(sev_rank "$up")"
    if [ "$n" -gt 0 ] && [ "$r" -gt "$HIGHEST" ]; then HIGHEST="$r"; HIGHEST_NAME="$up"; fi
  done
  [ "$WEB_TOTAL" -eq 0 ] || WEB_ITEMS="$(web_finding_items "$WEB_SRID")"
fi

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
[ -z "$WEB_SRID" ] || info "view scan" "$WEB_LABEL: ${APP_URL}/web-targets/${WEB_TARGET_ID}"

# combine all findings, tagging each with its scan's category, for the table
ALL_ITEMS="[]"
for i in "${!SCANS[@]}"; do
  ALL_ITEMS="$(jq -c --argjson acc "$ALL_ITEMS" --arg category "${SCAN_CATEGORIES[$i]}" \
    '$acc + (map(. + {category:$category}))' <<<"${SCAN_ITEMS[$i]}")"
done

# --- outputs ---------------------------------------------------------------
output_lines() {
  echo "scan-result-ids=$SCAN_IDS"
  echo "highest-severity=$(echo "$HIGHEST_NAME" | tr '[:upper:]' '[:lower:]')"
  echo "passed=$PASSED"
  if [ -n "$WEB_SRID" ]; then
    echo "web-target-id=$WEB_TARGET_ID"
    echo "web-scan-result-id=$WEB_SRID"
  fi
}
# A GitLab dotenv report accepts only [A-Za-z0-9_] names.
dotenv_lines() {
  output_lines | awk '{ i = index($0, "="); k = toupper(substr($0, 1, i - 1)); gsub("-", "_", k)
                        print "VULNARA_" k "=" substr($0, i + 1) }'
}
if [ "$CI_PLATFORM" = "github" ]; then
  [ -z "${GITHUB_OUTPUT:-}" ] || output_lines >> "$GITHUB_OUTPUT"
elif [ -n "$REPORT_DIR" ]; then
  mkdir -p "$REPORT_DIR"
  dotenv_lines > "$REPORT_DIR/outputs.env"
fi

# --- job summary -----------------------------------------------------------
render_summary() {
  local verdict badge repo_md shown
  if [ "$PASSED" = "true" ]; then verdict="Passed"; badge="✅"; else verdict="Failed"; badge="❌"; fi
  repo_md="\`$REPO_FULLNAME\`"
  [ -z "$REPO_URL" ] || repo_md="[\`$REPO_FULLNAME\`]($REPO_URL)"
  {
    echo "## $badge Vulnara scan: $verdict"
    echo ""
    echo "| | |"
    echo "|---|---|"
    if [ "$REPO_SCAN" = "true" ]; then
      echo "| Repository | $repo_md |"
      echo "| Provider | $REPO_PROVIDER ($REPO_VISIBILITY) |"
      echo "| Branch | \`$BRANCH\` |"
      echo "| Languages | $REPO_LANGS |"
    fi
    if [ -n "$WEB_SRID" ]; then
      echo "| Web target | [$(md_cell "$WEB_TARGET_NAME")]($APP_URL/web-targets/$WEB_TARGET_ID) |"
    fi
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
    if [ -n "$WEB_SRID" ]; then
      echo "| $WEB_LABEL | ${WEB_DURATION:-?}s | $WEB_TOTAL | [\`${WEB_SRID:0:8}\`]($APP_URL/web-targets/$WEB_TARGET_ID) |"
    fi
    if [ "$(echo "$ALL_ITEMS" | jq 'length')" -gt 0 ]; then
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
    if [ -n "$WEB_SRID" ]; then
      echo ""
      echo "### $WEB_LABEL"
      echo ""
      echo "| | |"
      echo "|---|---|"
      echo "| Target | [$(md_cell "$WEB_TARGET_NAME")]($APP_URL/web-targets/$WEB_TARGET_ID) |"
      echo "| URL | \`$(md_cell "$WEB_TARGET_URL")\` |"
      echo "| Scan | completed in ${WEB_DURATION:-?}s |"
      echo ""
      echo "| Critical | High | Medium | Low | Total |"
      echo "|---|---|---|---|---|"
      echo "$WEB_COUNTS" | jq -r --argjson t "$WEB_TOTAL" '"| \(.CRITICAL) | \(.HIGH) | \(.MEDIUM) | \(.LOW) | \($t) |"'
      if [ "$WEB_TOTAL" -gt 0 ]; then
        echo ""
        echo "| Severity | Finding | Matched at | CVE / CWE |"
        echo "|---|---|---|---|"
        echo "$WEB_ITEMS" | jq -r '
          def md: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|");
          def sevlabel(s): (s // "" | ascii_upcase) as $u
            | if $u=="CRITICAL" then "Critical" elif $u=="HIGH" then "High" elif $u=="MEDIUM" then "Medium" elif $u=="LOW" then "Low" else (s // "-") end;
          .[] | "| " + sevlabel(.severity) + " | " + ((.name // .templateId // "-") | md)
            + " | `" + ((.matchedAt // "-") | md | gsub("`"; "")) + "` | "
            + (((.cveIds // []) + (.cweIds // [])) | if length == 0 then "-" else join(", ") | md end) + " |"'
        if [ "$WEB_TOTAL" -gt "$FINDING_LIMIT" ]; then
          echo ""
          echo "_Showing the top $FINDING_LIMIT of $WEB_TOTAL findings. Open the web target in Vulnara to see all._"
        fi
      fi
    fi
  }
}
if [ "$CI_PLATFORM" = "github" ]; then
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || render_summary >> "$GITHUB_STEP_SUMMARY"
elif [ -n "$REPORT_DIR" ]; then
  render_summary > "$REPORT_DIR/summary.md"
  if [ "$CI_PLATFORM" = "gitlab" ]; then
    group "Vulnara summary"
    cat "$REPORT_DIR/summary.md" >&2
    endgroup
  fi
fi

hr
log "findings -> critical=${SEV_TOTAL[CRITICAL]} high=${SEV_TOTAL[HIGH]} medium=${SEV_TOTAL[MEDIUM]} low=${SEV_TOTAL[LOW]} (total $TOTAL) in ${RUN_TIME}s"
if [ "$PASSED" = "false" ]; then
  fail "scan gate failed: highest severity '$HIGHEST_LABEL' meets/exceeds fail-on '$FAIL_ON'"
fi
log "✓ scan gate passed (fail-on: $FAIL_ON, highest: $HIGHEST_LABEL)"
hr
