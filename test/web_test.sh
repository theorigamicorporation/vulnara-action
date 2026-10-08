#!/usr/bin/env bash
# Tests for the web application scan (web-target-id / web-url).
# Source: openspec/specs/scan-orchestration/spec.md (Run a web application scan),
#         openspec/specs/action-configuration/spec.md (Validate the web application inputs),
#         openspec/specs/findings-gate-reporting/spec.md (Gate and report web application findings)

WEB_ID="aaaaaaaa-0000-0000-0000-000000000001"

web_files() {
  export GITHUB_OUTPUT="$WORKDIR/github_output"
  export GITHUB_STEP_SUMMARY="$WORKDIR/summary.md"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"
  env_set "GITHUB_OUTPUT" "$GITHUB_OUTPUT"
  env_set "GITHUB_STEP_SUMMARY" "$GITHUB_STEP_SUMMARY"
}

# A web-only run: no scan-tools, no repository to resolve.
web_only() {
  env_set "INPUT_SCAN-TOOLS" ""
  env_set "INPUT_REPOSITORY" ""
  env_set "INPUT_BRANCH" ""
  env_set "INPUT_WEB-TARGET-ID" "$WEB_ID"
}

web_counts() { # critical high medium low
  fixture webFindingCounts.json <<J
{"data":{"c":{"total":$1},"h":{"total":$2},"m":{"total":$3},"l":{"total":$4}}}
J
}

gql_error() { # code [message]
  printf '{"errors":[{"message":"%s","extensions":{"code":"%s"}}]}' "${2:-API Error occured}" "$1"
}

# --- validation --------------------------------------------------------------

# spec: action-configuration / Requirement: Validate configuration before scanning /
#       Scenario: Nothing to scan
test_no_scan_tools_and_no_web_input_still_requires_scan_tools() {
  env_set "INPUT_SCAN-TOOLS" ""
  run_action
  assert_failure
  assert_contains "$ERR" "::error::scan-tools is required"
  assert_eq "0" "$(request_count)" "no request before validation passes"
}

# spec: action-configuration / Requirement: Validate the web application inputs /
#       Scenario: web-url without consent
test_web_url_without_consent_is_refused_before_any_request() {
  local v
  for v in "" "false" "TRUE" "yes" "1"; do
    : > "$STUB_DIR/requests.log"
    env_set "INPUT_WEB-URL" "https://preview.example.com"
    env_set "INPUT_WEB-OWNERSHIP-CONSENT" "$v"
    run_action
    assert_failure "consent '$v' must not be accepted"
    assert_contains "$ERR" "web-url requires web-ownership-consent: true" "consent '$v' names the requirement"
    assert_eq "0" "$(request_count)" "no request is sent for consent '$v'"
  done
}

# spec: action-configuration / Requirement: Validate the web application inputs /
#       Scenario: Both web inputs
test_web_target_id_and_web_url_together_are_refused() {
  env_set "INPUT_WEB-TARGET-ID" "$WEB_ID"
  env_set "INPUT_WEB-URL" "https://preview.example.com"
  env_set "INPUT_WEB-OWNERSHIP-CONSENT" "true"
  run_action
  assert_failure
  assert_contains "$ERR" "set web-target-id or web-url, not both"
  assert_eq "0" "$(request_count)" "no request is sent"
}

# spec: action-configuration / Requirement: Validate the web application inputs /
#       Scenario: URL with credentials
test_web_url_with_credentials_is_refused_and_not_echoed() {
  env_set "INPUT_WEB-URL" "https://user:hunter2@preview.example.com/app"
  env_set "INPUT_WEB-OWNERSHIP-CONSENT" "true"
  run_action
  assert_failure
  assert_contains "$ERR" "web-url must not carry credentials"
  assert_not_contains "$ERR" "hunter2" "the password never reaches the log"
  assert_eq "0" "$(request_count)" "no request is sent"
}

# spec: action-configuration / Requirement: Validate the web application inputs
test_web_url_must_be_http_or_https() {
  env_set "INPUT_WEB-URL" "ftp://preview.example.com"
  env_set "INPUT_WEB-OWNERSHIP-CONSENT" "true"
  run_action
  assert_failure
  assert_contains "$ERR" "is not an http(s) URL"
  assert_eq "0" "$(request_count)" "no request is sent"
}

# spec: action-configuration / Requirement: Validate the web application inputs
test_web_target_id_must_be_an_id() {
  env_set "INPUT_WEB-TARGET-ID" "my-preview"
  run_action
  assert_failure
  assert_contains "$ERR" "web-target-id 'my-preview' is not a web target id"
  assert_eq "0" "$(request_count)" "no request is sent"
}

# spec: action-configuration / Requirement: Validate the web application inputs /
#       Scenario: web-target-id needs no consent
# spec: action-configuration / Requirement: Validate configuration before scanning /
#       Scenario: Web-only run needs no repository
test_web_only_run_needs_no_repository_branch_or_consent() {
  web_only
  unset GITHUB_REPOSITORY GITHUB_REF_NAME
  run_action
  assert_success
  assert_eq "0" "$(graphql_count repositories)" "the repository is not resolved"
  assert_eq "0" "$(graphql_count dockerScanTools)" "no scan tool is resolved"
  assert_eq "0" "$(graphql_count startRepositoryScan)" "no repository scan is started"
  assert_contains "$ERR" "vulnara: [1/4] Authenticate service account"
  assert_contains "$ERR" "vulnara: [2/4] Resolve web target"
  assert_contains "$ERR" "vulnara: [3/4] Run scans"
  assert_contains "$ERR" "vulnara: [4/4] Evaluate findings"
}

# --- orchestration -------------------------------------------------------------

# spec: scan-orchestration / Requirement: Run a web application scan /
#       Scenario: Web-only run
test_web_only_run_starts_a_web_scan_of_the_target() {
  web_only
  run_action
  assert_success
  assert_eq "1" "$(graphql_count webTarget)" "the target is read once"
  assert_eq "1" "$(graphql_count startWebScan)" "one web scan is started"
  assert_eq "$WEB_ID" "$(graphql_body_for startWebScan | jq -r '.variables.i.webTargetId')" "the target id is sent"
  assert_eq "web-scan-00000001" "$(graphql_body_for webScanResult | head -1 | jq -r '.variables.id')" "the scan result is polled"
  assert_eq "0" "$(graphql_count createWebTarget)" "nothing is registered"
  assert_contains "$ERR" "started 'Web application' -> scan web-scan-00000001"
  assert_contains "$ERR" "Web application completed in"
}

# spec: scan-orchestration / Requirement: Run a web application scan
test_web_scan_runs_alongside_the_repository_scan() {
  env_set "INPUT_WEB-TARGET-ID" "$WEB_ID"
  run_action
  assert_success
  assert_eq "1" "$(graphql_count startRepositoryScan)" "the repository scan still runs"
  assert_eq "1" "$(graphql_count startWebScan)" "the web scan runs too"
  assert_contains "$ERR" "vulnara: [4/6] Resolve web target"
  assert_contains "$ERR" "vulnara: [6/6] Evaluate findings"
  assert_contains "$ERR" "waiting for 2 scan(s) to finish"
  # the web scan is started after the repository scan, and both before any wait
  local order; order="$(cut -f1 "$STUB_DIR/graphql.log" | grep -nE '^(startRepositoryScan|startWebScan|scanResult|webScanResult)$' | cut -d: -f2 | uniq | tr '\n' ' ')"
  assert_eq "startRepositoryScan startWebScan scanResult webScanResult " "$order" "start both, then wait"
}

# spec: scan-orchestration / Requirement: Run a web application scan
test_a_repository_only_run_is_unchanged() {
  run_action
  assert_success
  assert_contains "$ERR" "vulnara: [5/5] Evaluate findings"
  assert_eq "0" "$(graphql_count scanCategories)" "no web request without a web input"
  assert_eq "0" "$(graphql_count startWebScan)" "no web scan without a web input"
}

# spec: scan-orchestration / Requirement: Run a web application scan /
#       Scenario: Web scanning not enabled
test_web_scanning_not_enabled_fails_before_registering_anything() {
  web_only
  env_set "INPUT_WEB-TARGET-ID" ""
  env_set "INPUT_WEB-URL" "https://preview.example.com"
  env_set "INPUT_WEB-OWNERSHIP-CONSENT" "true"
  fixture scanCategories.json <<'J'
{"data":{"scanCategories":["SAST","SCA"]}}
J
  run_action
  assert_failure
  assert_contains "$ERR" "web application scanning is not enabled for workspace 'tenant-abc'"
  assert_eq "0" "$(graphql_count webTargets)" "no target is looked up"
  assert_eq "0" "$(graphql_count createWebTarget)" "nothing is registered"
  assert_eq "0" "$(graphql_count startWebScan)" "nothing is started"
}

# spec: scan-orchestration / Requirement: Run a web application scan /
#       Scenario: Web scanning not enabled
test_web_scanning_check_runs_before_any_repository_scan_starts() {
  env_set "INPUT_WEB-TARGET-ID" "$WEB_ID"
  fixture scanCategories.json <<'J'
{"data":{"scanCategories":[]}}
J
  run_action
  assert_failure
  assert_contains "$ERR" "web application scanning is not enabled"
  assert_eq "0" "$(graphql_count startRepositoryScan)" "no repository scan is started either"
}

# spec: scan-orchestration / Requirement: Run a web application scan /
#       Scenario: Start refused for want of a scanner
test_start_refused_with_no_scanner_for_category() {
  web_only
  gql_error NO_SCANNER_FOR_CATEGORY | fixture startWebScan.json
  run_action
  assert_failure
  assert_contains "$ERR" "::error::web application scanning is not enabled for workspace 'tenant-abc'"
  assert_contains "$ERR" "NO_SCANNER_FOR_CATEGORY" "the gateway's code is printed too"
}

# spec: scan-orchestration / Requirement: Run a web application scan
test_start_refused_by_a_plan_limit() {
  web_only
  gql_error DAST_SCAN_MINUTES_LIMIT_EXCEEDED "Web scan limit exceeded" | fixture startWebScan.json
  run_action
  assert_failure
  assert_contains "$ERR" "plan limit for web application scanning is reached (DAST_SCAN_MINUTES_LIMIT_EXCEEDED)"
}

# spec: scan-orchestration / Requirement: Run a web application scan
test_start_refused_for_a_non_public_target() {
  web_only
  gql_error WEB_TARGET_ADDRESS_REFUSED | fixture startWebScan.json
  run_action
  assert_failure
  assert_contains "$ERR" "does not resolve to public addresses only"
}

# spec: scan-orchestration / Requirement: Run a web application scan
test_unknown_web_target_id_fails_with_not_found() {
  web_only
  gql_error NOT_FOUND "Web target not found" | fixture webTarget.json
  run_action
  assert_failure
  assert_contains "$ERR" "web-target-id '$WEB_ID': web target not found in workspace 'tenant-abc'"
  assert_eq "0" "$(graphql_count startWebScan)" "nothing is started"
}

# spec: scan-orchestration / Requirement: Run a web application scan /
#       Scenario: Registered URL reused
test_web_url_reuses_the_matching_target() {
  web_only
  env_set "INPUT_WEB-TARGET-ID" ""
  env_set "INPUT_WEB-URL" "https://App.Example.com"
  env_set "INPUT_WEB-OWNERSHIP-CONSENT" "true"
  fixture webTargets.json <<'J'
{"data":{"webTargets":{"total":2,"items":[
  {"id":"aaaaaaaa-0000-0000-0000-00000000000f","name":"Shop","baseUrl":"https://app.example.com/shop"},
  {"id":"aaaaaaaa-0000-0000-0000-000000000009","name":"App","baseUrl":"https://app.example.com/"}]}}}
J
  run_action
  assert_success
  assert_eq "app.example.com" "$(graphql_body_for webTargets | jq -r '.variables.l.filters[0].stringEquals')" "listed by host"
  assert_eq "0" "$(graphql_count createWebTarget)" "nothing is registered"
  assert_eq "aaaaaaaa-0000-0000-0000-000000000009" "$(graphql_body_for startWebScan | jq -r '.variables.i.webTargetId')" \
    "the target whose base URL matches is scanned, not the one under a longer path"
  assert_contains "$ERR" "resolved web target 'App'"
}

# spec: scan-orchestration / Requirement: Run a web application scan /
#       Scenario: Unregistered URL registered
test_web_url_registers_an_unknown_url_with_consent() {
  web_only
  env_set "INPUT_WEB-TARGET-ID" ""
  env_set "INPUT_WEB-URL" "https://new.example.com"
  env_set "INPUT_WEB-OWNERSHIP-CONSENT" "true"
  run_action
  assert_success
  local body; body="$(graphql_body_for createWebTarget)"
  assert_eq "https://new.example.com" "$(echo "$body" | jq -r '.variables.i.baseUrl')" "the URL is registered"
  assert_eq "true" "$(echo "$body" | jq -r '.variables.i.ownershipConsent')" "with the workflow's consent"
  assert_eq "aaaaaaaa-0000-0000-0000-000000000002" "$(graphql_body_for startWebScan | jq -r '.variables.i.webTargetId')" "the new target is scanned"
  assert_contains "$ERR" "registered 'https://new.example.com/' as a web target"
}

# spec: scan-orchestration / Requirement: Run a web application scan
test_registration_refused_by_the_gateway_fails_with_its_reason() {
  web_only
  env_set "INPUT_WEB-TARGET-ID" ""
  env_set "INPUT_WEB-URL" "https://intranet"
  env_set "INPUT_WEB-OWNERSHIP-CONSENT" "true"
  fixture createWebTarget.json <<'J'
{"errors":[{"message":"Validation error","extensions":{"code":"VALIDATION_ERROR","fields":[{"field":"baseUrl","code":"INVALID","message":"https://intranet is not public"}]}}]}
J
  run_action
  assert_failure
  assert_contains "$ERR" "registering web-url 'https://intranet': the gateway rejected the request: baseUrl: https://intranet is not public"
  assert_eq "0" "$(graphql_count startWebScan)" "nothing is started"
}

# spec: scan-orchestration / Requirement: Run a web application scan /
#       Scenario: Ambiguous URL
test_web_url_matching_two_targets_fails() {
  web_only
  env_set "INPUT_WEB-TARGET-ID" ""
  env_set "INPUT_WEB-URL" "https://app.example.com/"
  env_set "INPUT_WEB-OWNERSHIP-CONSENT" "true"
  fixture webTargets.json <<'J'
{"data":{"webTargets":{"total":2,"items":[
  {"id":"aaaaaaaa-0000-0000-0000-000000000007","name":"A","baseUrl":"https://app.example.com/"},
  {"id":"aaaaaaaa-0000-0000-0000-000000000008","name":"B","baseUrl":"https://app.example.com/"}]}}}
J
  run_action
  assert_failure
  assert_contains "$ERR" "matches 2 web targets"
  assert_contains "$ERR" "Pass the one to scan as web-target-id"
  assert_eq "0" "$(graphql_count createWebTarget)" "nothing is registered"
  assert_eq "0" "$(graphql_count startWebScan)" "nothing is started"
}

# spec: scan-orchestration / Requirement: Run a web application scan
test_url_key_normalisation() {
  local key u want
  while IFS='|' read -r u want; do
    key="$(prelude_run "jq -rn --arg u '$u' \"\$JQ_URL_KEY\"' \$u | urlkey'")"
    assert_eq "$want" "$key" "key of $u"
  done <<'T'
https://App.Example.com|https://app.example.com/
HTTPS://app.example.com./|https://app.example.com/
https://app.example.com:8443/x#frag|https://app.example.com:8443/x
https://app.example.com?q=1|https://app.example.com/?q=1
https://app.example.com/Shop|https://app.example.com/Shop
T
  assert_eq "app.example.com" "$(prelude_call web_url_host 'https://App.Example.com.:8443/x')" "host for the list filter"
}

# spec: scan-orchestration / Requirement: Run a web application scan /
#       Scenario: Web scan fails or times out
test_failed_web_scan_fails_the_run() {
  web_only
  fixture webScanResult.json <<'J'
{"data":{"webScanResult":{"status":"FAILED"}}}
J
  run_action
  assert_failure
  assert_contains "$ERR" "scan for 'Web application' ended as FAILED (id web-scan-00000001)"
}

# spec: scan-orchestration / Requirement: Run a web application scan /
#       Scenario: Web scan fails or times out
test_web_scan_polls_until_done_and_times_out() {
  web_only
  env_set "INPUT_WAIT-TIMEOUT" "0"
  fixture webScanResult.json <<'J'
{"data":{"webScanResult":{"status":"RUNNING"}}}
J
  run_action
  assert_failure
  assert_contains "$ERR" "timed out after 0s waiting for 'Web application' (still RUNNING, id web-scan-00000001)"
}

# spec: scan-orchestration / Requirement: Run a web application scan
test_web_scan_polls_every_poll_interval() {
  web_only
  env_set "INPUT_POLL-INTERVAL" "7"
  fixture webScanResult.1.json <<'J'
{"data":{"webScanResult":{"status":"PENDING"}}}
J
  fixture webScanResult.2.json <<'J'
{"data":{"webScanResult":{"status":"RUNNING"}}}
J
  run_action
  assert_success
  assert_eq "3" "$(graphql_count webScanResult)" "polled until SUCCESS"
  assert_eq "7
7" "$(cat "$STUB_DIR/sleep.log")" "slept poll-interval between polls"
}

# --- gate, outputs, summary ------------------------------------------------------

# spec: findings-gate-reporting / Requirement: Gate and report web application findings /
#       Scenario: A critical web finding trips the gate
test_a_critical_web_finding_trips_the_gate() {
  web_only
  web_files
  env_set "INPUT_FAIL-ON" "high"
  web_counts 1 0 2 0
  fixture webFindingItems.json <<'J'
{"data":{"c":{"items":[{"id":"f1","templateId":"CVE-2021-44228","name":"Log4j RCE","severity":"critical","matchedAt":"https://preview.example.com/api","cveIds":["CVE-2021-44228"],"cweIds":["CWE-502"]}]},
"h":{"items":[]},
"m":{"items":[{"id":"f2","templateId":"missing-csp","name":null,"severity":"medium","matchedAt":"https://preview.example.com/a|b","cveIds":[],"cweIds":[]},{"id":"f3","templateId":"x","name":"X","severity":"medium","matchedAt":"https://preview.example.com/","cveIds":[],"cweIds":["CWE-79"]}]},
"l":{"items":[]}}}
J
  run_action
  assert_failure
  assert_contains "$ERR" "::error::scan gate failed: highest severity 'Critical' meets/exceeds fail-on 'high'"
  local out; out="$(outputs)"
  assert_contains "$out" "highest-severity=critical"
  assert_contains "$out" "passed=false"
  assert_contains "$out" "web-target-id=$WEB_ID"
  assert_contains "$out" "web-scan-result-id=web-scan-00000001"
  assert_contains "$out" "scan-result-ids=" "scan-result-ids is still written"
  assert_not_contains "$out" "scan-result-ids=web-scan" "scan-result-ids stays repository scans only"
  # the counting request filters on the scan and each severity
  local body; body="$(graphql_body_for webFindingCounts)"
  assert_eq "web-scan-00000001" "$(echo "$body" | jq -r '.variables.c.filters[] | select(.field=="scanResultId") | .stringEquals')"
  assert_eq "CRITICAL HIGH MEDIUM LOW" "$(echo "$body" | jq -r '[.variables.c, .variables.h, .variables.m, .variables.l | .filters[] | select(.field=="severity") | .stringEquals] | join(" ")')"
  local s; s="$(summary)"
  assert_contains "$s" "### Web application"
  assert_contains "$s" "| Web target | [Preview](https://app.example.test/web-targets/$WEB_ID) |"
  assert_contains "$s" "| Web application | "
  assert_contains "$s" "| 1 | 0 | 2 | 0 | 3 |"
  assert_contains "$s" "| Critical | Log4j RCE | \`https://preview.example.com/api\` | CVE-2021-44228, CWE-502 |"
  assert_contains "$s" "| Medium | missing-csp | \`https://preview.example.com/a\\|b\` | - |" "the check id stands in for a missing name, pipes escaped"
  assert_not_contains "$s" "| Repository |" "a web-only summary has no repository rows"
}

# spec: findings-gate-reporting / Requirement: Gate and report web application findings
test_web_findings_below_the_gate_pass() {
  web_only
  web_files
  env_set "INPUT_FAIL-ON" "high"
  web_counts 0 0 0 3
  run_action
  assert_success
  assert_contains "$(outputs)" "highest-severity=low"
  assert_contains "$(outputs)" "passed=true"
}

# spec: findings-gate-reporting / Requirement: Gate and report web application findings
test_no_web_findings_skips_the_item_query() {
  web_only
  web_files
  run_action
  assert_success
  assert_eq "0" "$(graphql_count webFindingItems)" "no item request when nothing was found"
  assert_contains "$(outputs)" "highest-severity=none"
  assert_contains "$(summary)" "| 0 | 0 | 0 | 0 | 0 |"
}

# spec: findings-gate-reporting / Requirement: Gate and report web application findings /
#       Scenario: Web findings totalled with repository findings
test_web_findings_are_totalled_with_repository_findings() {
  env_set "INPUT_WEB-TARGET-ID" "$WEB_ID"
  web_files
  env_set "INPUT_FAIL-ON" "none"
  fixture scanFindings.json <<'J'
{"data":{"scanFindings":{"items":[{"id":"r1","severity":"HIGH","file":"a.py","line":1,"confidence":"HIGH","commitScan":{"commitHash":"abc"}}]}}}
J
  web_counts 0 0 2 0
  run_action
  assert_success
  assert_contains "$ERR" "findings -> critical=0 high=1 medium=2 low=0 (total 3)"
  assert_contains "$(outputs)" "highest-severity=high"
  local s; s="$(summary)"
  assert_contains "$s" "| Repository |" "the repository rows stay in a combined run"
  assert_contains "$s" "| 0 | 1 | 2 | 0 | 3 |" "run totals"
  assert_contains "$s" "| 0 | 0 | 2 | 0 | 2 |" "web totals"
}

# spec: scan-orchestration / Requirement: Never identify a scanner to the caller
test_web_scan_never_names_a_scanner() {
  web_only
  web_files
  web_counts 0 1 0 0
  fixture webFindingItems.json <<'J'
{"data":{"c":{"items":[]},"h":{"items":[{"id":"f","templateId":"t","name":"N","severity":"high","matchedAt":"https://p.example.com/","cveIds":[],"cweIds":[]}]},"m":{"items":[]},"l":{"items":[]}}}
J
  run_action
  local all; all="$ERR$(summary)$(outputs)"
  local w
  for w in nuclei Nuclei Hicks Ripley Bishop; do
    assert_not_contains "$all" "$w" "'$w' never appears"
  done
  # the queries do not ask for one either
  assert_not_contains "$(graphql_bodies)" "scanner" "no scanner field is selected"
}
