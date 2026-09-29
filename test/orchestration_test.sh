#!/usr/bin/env bash
# Tests for the scan-orchestration capability.
# Source: openspec/specs/scan-orchestration/spec.md

# spec: scan-orchestration / Requirement: Authenticate the service account /
#       Scenario: Successful token exchange
test_successful_token_exchange() {
  run_action
  assert_success
  assert_contains "$ERR" "authenticated as 'ci-bot' (tenant 'tenant-abc')" "auth log line"
  assert_contains "$ERR" "token valid ~3600s" "token lifetime reported"
  local log; log="$(requests_log)"
  assert_contains "$log" "grant_type=client_credentials" "client_credentials grant"
  assert_contains "$log" "client_id=test-client-id" "oauth client id"
  assert_contains "$log" "username=ci-bot" "service account as username"
  assert_contains "$log" "password=not-a-real-token" "token as password"
  assert_contains "$log" "scope=profile" "profile scope"
  assert_contains "$log" "Authorization: Bearer test-jwt-value" "bearer token on GraphQL calls"
}

# spec: scan-orchestration / Requirement: Authenticate the service account
test_token_lifetime_defaults_when_expires_in_missing() {
  fixture token.json <<'J'
{"access_token":"test-jwt-value"}
J
  run_action
  assert_success
  assert_contains "$ERR" "token valid ~3600s" "default lifetime is 3600s"
}

# spec: scan-orchestration / Requirement: Authenticate the service account /
#       Scenario: Token refreshed during a long scan
test_token_is_reused_until_it_nears_expiry() {
  run_action
  assert_success
  local token_calls
  token_calls="$(grep -c 'url=https://auth.example.test' "$STUB_DIR/requests.log")"
  assert_eq "1" "$token_calls" "a long-lived token is exchanged once for the whole run"
}

# spec: scan-orchestration / Requirement: Authenticate the service account /
#       Scenario: Token refreshed during a long scan
test_token_is_refreshed_when_close_to_expiry() {
  # a token whose remaining lifetime is under the 120s refresh window is
  # re-exchanged before every GraphQL request instead of failing the job
  fixture token.json <<'J'
{"access_token":"test-jwt-value","expires_in":30}
J
  run_action
  assert_success
  local token_calls gql_calls
  token_calls="$(grep -c 'url=https://auth.example.test' "$STUB_DIR/requests.log")"
  gql_calls="$(graphql_count)"
  # one exchange for the explicit authenticate step plus one before each request
  assert_eq "$(( gql_calls + 1 ))" "$token_calls" "the token is refreshed before every request"
}

# spec: scan-orchestration / Requirement: Authenticate the service account /
#       Scenario: Invalid credentials
test_invalid_credentials_fail_with_the_provider_message() {
  fixture token.json <<'J'
{"error":"invalid_grant","error_description":"Invalid username or password"}
J
  run_action
  assert_failure "bad credentials must fail the job"
  assert_contains "$ERR" "Invalid username or password" "provider error_description surfaced"
  assert_contains "$ERR" "::error::could not authenticate the service account (check service-account/token/tenant)" \
    "authentication failure message"
  assert_eq "0" "$(graphql_count)" "no GraphQL request after a failed token exchange"
}

# spec: scan-orchestration / Requirement: Send tenant-scoped GraphQL requests
test_graphql_requests_are_tenant_scoped_json_posts() {
  run_action
  assert_success
  local log; log="$(requests_log)"
  assert_contains "$log" "X-Tenant: tenant-abc" "X-Tenant header"
  assert_contains "$log" "Content-Type: application/json" "json content type"
  # every request body is valid JSON built by jq
  while IFS= read -r body; do
    [ -n "$body" ] || continue
    printf '%s' "$body" | jq -e . >/dev/null 2>&1 || _fail_assert "request body is not valid JSON: $body"
  done < <(graphql_bodies)
}

# spec: scan-orchestration / Requirement: Send tenant-scoped GraphQL requests /
#       Scenario: GraphQL returns errors
test_graphql_errors_are_reported_and_fail_the_run() {
  fixture repositories.json <<'J'
{"errors":[{"message":"permission denied","extensions":{"code":"FORBIDDEN"}}]}
J
  run_action
  assert_failure "a GraphQL error must fail the run"
  assert_contains "$ERR" "FORBIDDEN: permission denied" "error code and message"
  assert_contains "$ERR" "::error::GraphQL request failed" "failure message"
}

# spec: scan-orchestration / Requirement: Send tenant-scoped GraphQL requests /
#       Scenario: GraphQL returns errors
test_graphql_error_without_extensions_uses_a_generic_code() {
  fixture scanFindings.json <<'J'
{"errors":[{"message":"boom"}]}
J
  run_action
  assert_failure "a GraphQL error must fail the run"
  assert_contains "$ERR" "ERROR: boom" "generic error code"
  assert_contains "$ERR" "::error::GraphQL request failed" "failure message"
}

# spec: scan-orchestration / Requirement: Resolve the repository in Vulnara /
#       Scenario: Repository resolved and reported
test_repository_is_resolved_and_reported() {
  run_action
  assert_success
  assert_info "Repository" "acme/widgets" "repository full name"
  assert_info "Vulnara id" "repo-1111" "vulnara repository id"
  assert_info "Provider" "github" "provider"
  assert_info "Visibility" "public" "visibility"
  assert_info "Branch" "feature/x" "branch"
  assert_info "Languages" "Go, Shell" "languages"
  assert_info "Enabled" "yes" "enabled flag"
  assert_info "URL" "https://git.example.test/acme/widgets" "browsing url from htmlUrl"
  assert_contains "$(graphql_body_for repositories)" '"stringEquals":"widgets"' "filtered by repository name"
}

# spec: scan-orchestration / Requirement: Resolve the repository in Vulnara /
#       Scenario: Repository resolved and reported
test_repository_owner_is_matched_case_insensitively() {
  env_set "INPUT_REPOSITORY" "ACME/widgets"
  fixture repositories.json <<'J'
{"data":{"repositories":{"items":[
  {"id":"repo-other","repositoryName":"widgets","private":false,"enabled":true,
   "programmingLanguage":[],"cloneUrl":"https://git.example.test/other/widgets.git",
   "gitEntity":{"__typename":"Organization","name":"other","gitType":"github","htmlUrl":"https://git.example.test/other"}},
  {"id":"repo-1111","repositoryName":"widgets","private":false,"enabled":true,
   "programmingLanguage":[],"cloneUrl":"https://git.example.test/acme/widgets.git",
   "gitEntity":{"__typename":"Organization","name":"Acme","gitType":"github","htmlUrl":"https://git.example.test/acme"}}
]}}}
J
  run_action
  assert_success
  assert_info "Vulnara id" "repo-1111" "owner match wins over list order"
  assert_info "Repository" "Acme/widgets" "full name uses the Vulnara entity name"
}

# spec: scan-orchestration / Requirement: Resolve the repository in Vulnara /
#       Scenario: Repository resolved and reported
test_repository_falls_back_to_the_first_item_when_no_owner_matches() {
  fixture repositories.json <<'J'
{"data":{"repositories":{"items":[
  {"id":"repo-first","repositoryName":"widgets","private":false,"enabled":true,
   "programmingLanguage":null,"cloneUrl":"https://git.example.test/other/widgets.git",
   "gitEntity":{"__typename":"GitUser","name":"other","gitType":"github","htmlUrl":null}}
]}}}
J
  run_action
  assert_success
  assert_info "Vulnara id" "repo-first" "first item used as fallback"
  assert_info "URL" "https://git.example.test/other/widgets" "cloneUrl fallback drops the .git suffix"
  assert_info "Languages" "n/a" "no languages reported as n/a"
}

# spec: scan-orchestration / Requirement: Build a browsing URL for every provider /
#       Scenario: Azure DevOps repository
test_azure_devops_browsing_url_includes_the_git_segment() {
  fixture repositories.json <<'J'
{"data":{"repositories":{"items":[
  {"id":"repo-1111","repositoryName":"web/widgets","private":false,"enabled":true,
   "programmingLanguage":["Go"],"cloneUrl":"https://dev.azure.com/acme/web/_git/widgets",
   "gitEntity":{"__typename":"Organization","name":"acme","gitType":"azure_devops","htmlUrl":"https://dev.azure.com/acme"}}
]}}}
J
  run_action
  assert_success
  assert_info "Provider" "azure_devops" "provider"
  assert_info "URL" "https://dev.azure.com/acme/web/_git/widgets" "project and _git segment"
}

# spec: scan-orchestration / Requirement: Build a browsing URL for every provider /
#       Scenario: Clone URL carries credentials
test_clone_url_fallback_drops_credentials() {
  fixture repositories.json <<'J'
{"data":{"repositories":{"items":[
  {"id":"repo-1111","repositoryName":"widgets","private":false,"enabled":true,
   "programmingLanguage":["Go"],"cloneUrl":"https://x-token-auth:secret@bitbucket.org/acme/widgets.git",
   "gitEntity":{"__typename":"Organization","name":"acme","gitType":"bitbucket","htmlUrl":null}}
]}}}
J
  run_action
  assert_success
  assert_info "URL" "https://bitbucket.org/acme/widgets" "userinfo stripped"
  assert_not_contains "$ERR" "secret@" "credentials never logged"
}

# spec: scan-orchestration / Requirement: Resolve the repository in Vulnara /
#       Scenario: Repository not present in Vulnara
test_repository_not_found_fails_the_run() {
  fixture repositories.json <<'J'
{"data":{"repositories":{"items":[]}}}
J
  run_action
  assert_failure "an unknown repository must fail the run"
  assert_contains "$ERR" "repository 'acme/widgets' was not found in Vulnara (tenant 'tenant-abc')" "not-found message"
  assert_contains "$ERR" "Add it in Vulnara first." "remediation hint"
  assert_eq "0" "$(graphql_count startRepositoryScan)" "no scan was started"
}

# spec: scan-orchestration / Requirement: Resolve the repository in Vulnara /
#       Scenario: Repository is disabled
test_disabled_repository_warns_and_continues() {
  fixture repositories.json <<'J'
{"data":{"repositories":{"items":[
  {"id":"repo-1111","repositoryName":"widgets","private":false,"enabled":false,
   "programmingLanguage":["Go"],"cloneUrl":"https://git.example.test/acme/widgets.git",
   "gitEntity":{"__typename":"Organization","name":"acme","gitType":"github","htmlUrl":"https://git.example.test/acme"}}
]}}}
J
  run_action
  assert_success "a disabled repository is a warning, not a failure"
  assert_info "Enabled" "no" "enabled flag reported as no"
  assert_contains "$ERR" "::warning::repository 'acme/widgets' is disabled in Vulnara" "warning annotation"
  assert_eq "1" "$(graphql_count startRepositoryScan)" "the scan is still started"
}

# spec: scan-orchestration / Requirement: Resolve the repository in Vulnara /
#       Scenario: Private repository without a git token
test_private_repository_without_git_token_warns() {
  fixture repositories.json <<'J'
{"data":{"repositories":{"items":[
  {"id":"repo-1111","repositoryName":"widgets","private":true,"enabled":true,
   "programmingLanguage":["Go"],"cloneUrl":"https://git.example.test/acme/widgets.git",
   "gitEntity":{"__typename":"Organization","name":"acme","gitType":"github","htmlUrl":"https://git.example.test/acme"}}
]}}}
J
  run_action
  assert_success "a private repository without a git token is a warning"
  assert_info "Visibility" "private" "visibility reported"
  assert_contains "$ERR" "::warning::repository is private but no git-token-id was provided" "warning annotation"
}

# spec: scan-orchestration / Requirement: Resolve the repository in Vulnara /
#       Scenario: Private repository without a git token
test_private_repository_with_git_token_does_not_warn() {
  env_set "INPUT_GIT-TOKEN-ID" "git-token-0001"
  fixture repositories.json <<'J'
{"data":{"repositories":{"items":[
  {"id":"repo-1111","repositoryName":"widgets","private":true,"enabled":true,
   "programmingLanguage":["Go"],"cloneUrl":"https://git.example.test/acme/widgets.git",
   "gitEntity":{"__typename":"Organization","name":"acme","gitType":"github","htmlUrl":"https://git.example.test/acme"}}
]}}}
J
  run_action
  assert_success
  assert_not_contains "$ERR" "no git-token-id was provided" "no warning when a git token is supplied"
  assert_contains "$(graphql_body_for startRepositoryScan)" '"gitTokenId":"git-token-0001"' "git token passed to the mutation"
}

# spec: scan-orchestration / Requirement: Resolve the requested scan tools /
#       Scenario: Tools resolved by name and by id
test_tools_resolved_by_name_and_by_id() {
  env_set "INPUT_SCAN-TOOLS" "aegis, 22222222-3333-4444-5555-666666666666"
  run_action
  assert_success
  assert_info "category" "Dependencies, Secrets (11111111-2222-3333-4444-555555555555)" "name match is case-insensitive"
  assert_info "category" "Personal data (22222222-3333-4444-5555-666666666666)" "id match"
  assert_contains "$ERR" "2 scan tool(s) selected" "tool count reported"
  assert_eq "2" "$(graphql_count startRepositoryScan)" "one scan per tool"
  assert_not_contains "$ERR" "AEGIS" "the stored name of a resolved tool is never logged"
  assert_not_contains "$ERR" "pdd" "the stored name of a tool resolved by id is never logged"
  for codename in Ripley Bishop Hicks Ash; do
    assert_not_contains "$ERR" "$codename" "the codename '$codename' is never logged"
  done
}

# spec: scan-orchestration / Requirement: Resolve the requested scan tools
test_tool_entries_are_trimmed() {
  env_set "INPUT_SCAN-TOOLS" "   trivy   "
  run_action
  assert_success
  assert_info "category" "Dependencies (33333333-4444-5555-6666-777777777777)" "surrounding whitespace trimmed"
  assert_contains "$ERR" "started 'Dependencies'" "the scan is logged under its category"
  assert_not_contains "$ERR" "Hicks" "the codename is not used as the label"
  assert_not_contains "$ERR" "trivy" "the stored name is not echoed back"
}

# spec: scan-orchestration / Requirement: Resolve the requested scan tools /
#       Scenario: Unknown tool requested
test_unknown_tool_names_the_entry_not_the_roster() {
  env_set "INPUT_SCAN-TOOLS" "AEGIS,nosuchtool"
  run_action
  assert_contains "$ERR" "::error::scan tool 'nosuchtool' is not available to tenant 'tenant-abc'." \
    "names the rejected entry and the tenant"
  assert_contains "$ERR" "https://app.example.test" "points at the Vulnara application"
  assert_failure "an unknown tool must fail the run"
  assert_eq "0" "$(graphql_count startRepositoryScan)" "no scan is started once a tool cannot be resolved"
}

# spec: scan-orchestration / Requirement: Never print a scanner's stored name /
#       Scenario: A scanner is named in the log or the summary
test_unknown_tool_failure_leaks_no_scanner_name() {
  env_set "INPUT_SCAN-TOOLS" "nosuchtool"
  run_action
  assert_failure "an unknown tool must fail the run"
  for stored in pdd trivy secret_scanner; do
    assert_not_contains "$ERR" "$stored" "the failure must not enumerate '$stored'"
  done
  assert_not_contains "$ERR" "Available:" "no roster is printed"
}

# spec: scan-orchestration / Requirement: Never identify a scanner to the caller /
#       Scenario: A scanner whose categories cannot be resolved
test_scanner_without_categories_is_reported_as_uncategorised() {
  env_set "INPUT_SCAN-TOOLS" "beyond-the-map"
  export GITHUB_STEP_SUMMARY="$WORKDIR/summary.md"
  : > "$GITHUB_STEP_SUMMARY"
  env_set "GITHUB_STEP_SUMMARY" "$GITHUB_STEP_SUMMARY"
  fixture dockerScanTools.json <<'J'
{"data":{"dockerScanTools":{"items":[
  {"id": "99999999-0000-1111-2222-333333333333", "name": "beyond-the-map", "categories": []}
]}}}
J
  run_action
  assert_success
  assert_info "category" "Uncategorised (99999999-0000-1111-2222-333333333333)" "a tool with no category is shown as Uncategorised"
  assert_contains "$ERR" "started 'Uncategorised'" "the scan is logged under the placeholder"
  assert_not_contains "$ERR" "beyond-the-map" "the stored name reaches no log line"
  assert_not_contains "$(summary)" "beyond-the-map" "the stored name reaches no summary row"
}

# spec: scan-orchestration / Requirement: Resolve the requested scan tools /
#       Scenario: The gateway has no categories field
# The gateway that ships today has no DockerScanTool.categories. Selecting it
# unconditionally would fail the whole query and start no scan, so the resolver
# narrows the selection and retries.
test_a_gateway_without_categories_still_resolves_and_scans() {
  fixture dockerScanTools.1.json <<'J'
{"errors":[{"message":"Cannot query field \"categories\" on type \"DockerScanTool\".","extensions":{"code":"GRAPHQL_VALIDATION_FAILED"}}]}
J
  fixture dockerScanTools.json <<'J'
{"data":{"dockerScanTools":{"items":[
  {"id": "11111111-2222-3333-4444-555555555555", "name": "AEGIS"}
]}}}
J
  run_action
  assert_success "a gateway without .categories must not fail the run"
  assert_info "category" "Uncategorised (11111111-2222-3333-4444-555555555555)" "no category is known, so the label is the fallback"
  assert_eq "1" "$(graphql_count startRepositoryScan)" "the scan is still started"
  assert_not_contains "$ERR" "GraphQL request failed" "the recoverable validation error is not surfaced"
  assert_not_contains "$ERR" "AEGIS" "the stored name is still not logged"
}

# spec: scan-orchestration / Requirement: Resolve the requested scan tools /
#       Scenario: The gateway has no name field
# Owner decision 3 removes DockerScanTool.name. An id pinned in a consumer's
# workflow file must keep working across that change: before this, the query
# selected `name` unconditionally, so an id-based run failed exactly as hard as
# a name-based one and the annotation blamed the caller's input.
test_a_gateway_without_name_still_resolves_an_id() {
  env_set "INPUT_SCAN-TOOLS" "11111111-2222-3333-4444-555555555555"
  fixture dockerScanTools.1.json <<'J'
{"errors":[{"message":"Cannot query field \"name\" on type \"DockerScanTool\".","extensions":{"code":"GRAPHQL_VALIDATION_FAILED"}}]}
J
  fixture dockerScanTools.json <<'J'
{"data":{"dockerScanTools":{"items":[
  {"id": "11111111-2222-3333-4444-555555555555", "categories": ["sca","secrets"]},
  {"id": "22222222-3333-4444-5555-666666666666", "categories": ["pii"]}
]}}}
J
  run_action
  assert_success "a pinned tool id must keep working once .name is removed"
  assert_info "category" "Dependencies, Secrets (11111111-2222-3333-4444-555555555555)" "resolved by id alone"
  assert_eq "1" "$(graphql_count startRepositoryScan)" "the scan is started"
  assert_not_contains "$ERR" "GraphQL request failed" "the recoverable validation error is not surfaced"
  assert_not_contains "$ERR" "not available to tenant" "the run does not blame the caller's input for a schema change"
}

# spec: scan-orchestration / Requirement: Resolve the requested scan tools /
#       Scenario: A name is requested from a gateway that resolves only ids
test_a_name_against_a_gateway_without_name_says_ids_are_required() {
  env_set "INPUT_SCAN-TOOLS" "AEGIS"
  fixture dockerScanTools.1.json <<'J'
{"errors":[{"message":"Cannot query field \"name\" on type \"DockerScanTool\".","extensions":{"code":"GRAPHQL_VALIDATION_FAILED"}}]}
J
  fixture dockerScanTools.json <<'J'
{"data":{"dockerScanTools":{"items":[
  {"id": "11111111-2222-3333-4444-555555555555", "categories": ["sca"]}
]}}}
J
  run_action
  assert_failure "a name that can no longer be resolved must fail the run"
  assert_contains "$ERR" "::error::scan tool 'AEGIS' is not a scan tool id, and this Vulnara gateway no longer resolves scan tools by name." \
    "the failure says what actually went wrong"
  assert_contains "$ERR" "https://app.example.test" "points at the Vulnara application for the id"
  assert_not_contains "$ERR" "is not available to tenant" "it does not blame the tenant's availability"
  assert_eq "0" "$(graphql_count startRepositoryScan)" "no scan is started"
}

# spec: scan-orchestration / Requirement: Send tenant-scoped GraphQL requests /
#       Scenario: GraphQL returns errors
# Narrowing the selection is only for a rejected optional field. Any other
# GraphQL error still aborts with the gateway's own wording.
test_a_non_field_error_on_the_catalogue_still_fails_the_run() {
  fixture dockerScanTools.json <<'J'
{"errors":[{"message":"tenant is not permitted to list scan tools","extensions":{"code":"FORBIDDEN"}}]}
J
  run_action
  assert_failure "a real GraphQL error must fail the run"
  assert_contains "$ERR" "FORBIDDEN: tenant is not permitted to list scan tools" "the gateway's error is printed"
  assert_contains "$ERR" "::error::GraphQL request failed" "the run aborts on it"
  assert_eq "0" "$(graphql_count startRepositoryScan)" "no scan is started"
}

# spec: scan-orchestration / Requirement: Resolve the requested scan tools /
#       Scenario: No usable tool entries
test_only_separators_yields_no_scan_tools() {
  env_set "INPUT_SCAN-TOOLS" " , ,  "
  run_action
  assert_contains "$ERR" "::error::no scan tools provided" "no scan tools message"
  assert_failure "an empty tool list must fail the run"
  assert_not_contains "$ERR" "scan tool(s) selected" "the run does not report a tool count"
  assert_eq "0" "$(graphql_count startRepositoryScan)" "no scan was started"
}

# spec: scan-orchestration / Requirement: Start one scan per tool /
#       Scenario: Scans started
test_scans_are_started_per_tool_with_the_resolved_input() {
  env_set "INPUT_SCAN-TOOLS" "AEGIS,trivy"
  env_set "INPUT_CREATE-ISSUE" "true"
  env_set "INPUT_AUTO-REMEDIATE" "true"
  run_action
  assert_success
  local bodies; bodies="$(graphql_body_for startRepositoryScan)"
  assert_contains "$bodies" '"repositoryId":"repo-1111"' "resolved repository id"
  assert_contains "$bodies" '"branch":"feature/x"' "branch"
  assert_contains "$bodies" '"dockerScanToolId":"11111111-2222-3333-4444-555555555555"' "first tool id"
  assert_contains "$bodies" '"dockerScanToolId":"33333333-4444-5555-6666-777777777777"' "second tool id"
  assert_contains "$bodies" '"createIssue":true' "createIssue boolean"
  assert_contains "$bodies" '"autoRemediate":true' "autoRemediate boolean"
  assert_contains "$ERR" "started 'Dependencies, Secrets' -> scan scan-aaaaaaaa-0001" "first scan logged with its category"
  assert_contains "$ERR" "started 'Dependencies' -> scan scan-bbbbbbbb-0002" "second scan logged with its category"
}

# spec: scan-orchestration / Requirement: Start one scan per tool
test_flags_default_to_false_booleans() {
  run_action
  assert_success
  local bodies; bodies="$(graphql_body_for startRepositoryScan)"
  assert_contains "$bodies" '"createIssue":false' "createIssue false"
  assert_contains "$bodies" '"autoRemediate":false' "autoRemediate false"
}

# spec: scan-orchestration / Requirement: Start one scan per tool /
#       Scenario: git-token-id omitted when unset
test_git_token_id_is_omitted_when_empty() {
  run_action
  assert_success
  assert_not_contains "$(graphql_body_for startRepositoryScan)" "gitTokenId" "no gitTokenId field"
}

# spec: scan-orchestration / Requirement: Start one scan per tool /
#       Scenario: Mutation returns no scan result id
test_missing_scan_result_id_fails_the_run() {
  fixture startRepositoryScan.1.json <<'J'
{"data":{"startRepositoryScan":{"scanResult":{"id":null,"status":"PENDING"}}}}
J
  run_action
  assert_failure "a missing scan result id must fail the run"
  assert_contains "$ERR" "::error::scan did not return a scan result id (tool 'Dependencies, Secrets')" "names the category"
}

# spec: scan-orchestration / Requirement: Wait for scans to finish /
#       Scenario: Scan completes successfully
test_scan_polls_until_success() {
  fixture scanResult.1.json <<'J'
{"data":{"scanResult":{"status":"PENDING"}}}
J
  fixture scanResult.2.json <<'J'
{"data":{"scanResult":{"status":"RUNNING"}}}
J
  fixture scanResult.3.json <<'J'
{"data":{"scanResult":{"status":"SUCCESS"}}}
J
  run_action
  assert_success
  assert_eq "3" "$(graphql_count scanResult)" "polled until the terminal status"
  assert_contains "$ERR" "PENDING (" "pending transition logged"
  assert_contains "$ERR" "RUNNING (" "running transition logged"
  assert_contains "$ERR" "Dependencies, Secrets completed in" "completion logged with the elapsed time"
  assert_eq "2" "$(sleep_count)" "slept between polls only"
  assert_contains "$(cat "$STUB_DIR/sleep.log")" "1" "slept for the poll-interval"
}

# spec: scan-orchestration / Requirement: Wait for scans to finish
test_missing_status_is_treated_as_pending() {
  fixture scanResult.1.json <<'J'
{"data":{"scanResult":{}}}
J
  fixture scanResult.2.json <<'J'
{"data":{"scanResult":{"status":"SUCCESS"}}}
J
  run_action
  assert_success
  assert_contains "$ERR" "PENDING (" "absent status reported as PENDING"
}

# spec: scan-orchestration / Requirement: Wait for scans to finish /
#       Scenario: Scan ends in a failure state
test_failed_scan_fails_the_run() {
  fixture scanResult.json <<'J'
{"data":{"scanResult":{"status":"FAILED"}}}
J
  run_action
  assert_failure "a FAILED scan must fail the run"
  assert_contains "$ERR" "::error::scan for 'Dependencies, Secrets' ended as FAILED (id scan-aaaaaaaa-0001)" "failure message"
  assert_eq "0" "$(graphql_count scanFindings)" "findings are not collected"
}

# spec: scan-orchestration / Requirement: Wait for scans to finish /
#       Scenario: Scan ends in a failure state
test_cancelled_scan_fails_the_run() {
  fixture scanResult.json <<'J'
{"data":{"scanResult":{"status":"CANCELLED"}}}
J
  run_action
  assert_failure "a CANCELLED scan must fail the run"
  assert_contains "$ERR" "ended as CANCELLED (id scan-aaaaaaaa-0001)" "failure message"
}

# spec: scan-orchestration / Requirement: Wait for scans to finish /
#       Scenario: Scan exceeds the wait timeout
test_scan_timeout_fails_the_run() {
  env_set "INPUT_WAIT-TIMEOUT" "0"
  fixture scanResult.json <<'J'
{"data":{"scanResult":{"status":"RUNNING"}}}
J
  run_action
  assert_failure "an unfinished scan must fail once the timeout passes"
  assert_contains "$ERR" "::error::timed out after 0s waiting for 'Dependencies, Secrets' (still RUNNING, id scan-aaaaaaaa-0001)" \
    "timeout message names the timeout, status and scan id"
}
