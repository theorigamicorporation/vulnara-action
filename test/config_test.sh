#!/usr/bin/env bash
# Tests for the action-configuration capability.
# Source: openspec/specs/action-configuration/spec.md

# spec: action-configuration / Requirement: Declare the action interface /
#       Scenario: Action metadata is resolvable by GitHub
test_action_metadata_declares_docker_runner() {
  local yml; yml="$(cat "$REPO_DIR/action.yml")"
  assert_contains "$yml" "using: 'docker'" "action.yml runs.using"
  assert_contains "$yml" "image: 'Dockerfile'" "action.yml runs.image"
  local df; df="$(cat "$REPO_DIR/Dockerfile")"
  for pkg in bash curl jq ca-certificates; do
    assert_contains "$df" "$pkg" "Dockerfile installs $pkg"
  done
  assert_contains "$df" 'ENTRYPOINT ["/entrypoint.sh"]' "Dockerfile entrypoint"
}

# spec: action-configuration / Requirement: Declare the action interface /
#       Scenario: Required inputs are marked required
test_action_metadata_inputs_and_outputs() {
  local yml; yml="$(cat "$REPO_DIR/action.yml")"
  for i in service-account token tenant scan-tools branch repository git-token-id \
           fail-on create-issue auto-remediate wait-timeout poll-interval \
           app-url gateway-url token-url oauth-client-id; do
    assert_contains "$yml" "  $i:" "input $i declared"
  done
  for o in scan-result-ids highest-severity passed; do
    assert_contains "$yml" "  $o:" "output $o declared"
  done
  # the four required inputs, and only those, are required: true
  local required_count
  required_count="$(grep -c 'required: true' "$REPO_DIR/action.yml")"
  assert_eq "4" "$required_count" "exactly four required inputs"
  # every optional input carries a default
  local optional_count default_count
  optional_count="$(grep -c 'required: false' "$REPO_DIR/action.yml")"
  default_count="$(grep -c '    default:' "$REPO_DIR/action.yml")"
  assert_eq "$optional_count" "$default_count" "every optional input has a default"
}

# spec: action-configuration / Requirement: Read dashed input environment variables /
#       Scenario: Dashed variable is present
test_input_reads_dashed_variable() {
  env_set "INPUT_SERVICE-ACCOUNT" "dashed-bot"
  env_set "INPUT_SERVICE_ACCOUNT" "underscore-bot"
  assert_eq "dashed-bot" "$(prelude_call input service-account)" "dashed variable wins"
  assert_eq "dashed-bot" "$(prelude_var SERVICE_ACCOUNT)" "resolved input"
}

# spec: action-configuration / Requirement: Read dashed input environment variables /
#       Scenario: Only the underscore variable is present
test_input_falls_back_to_underscore_variable() {
  env_unset "INPUT_SERVICE-ACCOUNT"
  env_set "INPUT_SERVICE_ACCOUNT" "underscore-bot"
  assert_eq "underscore-bot" "$(prelude_call input service-account)" "underscore fallback"
  env_set "INPUT_SERVICE-ACCOUNT" ""
  assert_eq "underscore-bot" "$(prelude_call input service-account)" "empty dashed falls back too"
}

test_input_returns_empty_for_unset_variable() {
  assert_eq "" "$(prelude_call input no-such-input)" "unset input is empty"
}

# spec: action-configuration / Requirement: Default optional inputs /
#       Scenario: Branch and repository inferred from the workflow
test_branch_and_repository_default_to_github_env() {
  env_set "INPUT_BRANCH" ""
  env_set "INPUT_REPOSITORY" ""
  env_set "GITHUB_REF_NAME" "feature/x"
  env_set "GITHUB_REPOSITORY" "acme/widgets"
  assert_eq "feature/x" "$(prelude_var BRANCH)" "branch from GITHUB_REF_NAME"
  assert_eq "acme/widgets" "$(prelude_var REPOSITORY)" "repository from GITHUB_REPOSITORY"
}

# spec: action-configuration / Requirement: Default optional inputs
test_optional_inputs_have_documented_defaults() {
  for v in INPUT_FAIL-ON INPUT_CREATE-ISSUE INPUT_AUTO-REMEDIATE INPUT_WAIT-TIMEOUT \
           INPUT_POLL-INTERVAL INPUT_APP-URL INPUT_GATEWAY-URL INPUT_TOKEN-URL \
           INPUT_OAUTH-CLIENT-ID; do
    env_set "$v" ""
  done
  assert_eq "critical" "$(prelude_var FAIL_ON)"        "fail-on default"
  assert_eq "4"        "$(prelude_var FAIL_RANK)"      "critical threshold rank"
  assert_eq "false"    "$(prelude_var CREATE_ISSUE)"   "create-issue default"
  assert_eq "false"    "$(prelude_var AUTO_REMEDIATE)" "auto-remediate default"
  assert_eq "1800"     "$(prelude_var WAIT_TIMEOUT)"   "wait-timeout default"
  assert_eq "15"       "$(prelude_var POLL_INTERVAL)"  "poll-interval default"
  assert_eq "https://vulnara.rso.dev"            "$(prelude_var APP_URL)"     "app-url default"
  assert_eq "https://vulnara-gw.rso.dev/graphql" "$(prelude_var GATEWAY_URL)" "gateway-url default"
  assert_contains "$(prelude_var TOKEN_URL)" "/application/o/token/" "token-url default"
  assert_eq "50" "$(prelude_var FINDING_LIMIT)" "detailed findings cap"
}

# spec: action-configuration / Requirement: Default optional inputs
test_app_url_trailing_slash_is_stripped() {
  env_set "INPUT_APP-URL" "https://app.example.test/"
  assert_eq "https://app.example.test" "$(prelude_var APP_URL)" "trailing slash stripped"
}

# spec: action-configuration / Requirement: Default optional inputs /
#       Scenario: Non-prod endpoints overridden
test_non_prod_endpoints_are_used_for_every_request() {
  env_set "INPUT_APP-URL" "https://app.example.test/"
  export GITHUB_STEP_SUMMARY="$WORKDIR/summary.md"
  env_set "GITHUB_STEP_SUMMARY" "$WORKDIR/summary.md"
  run_action
  assert_success
  local log; log="$(requests_log)"
  assert_contains "$log" "url=https://auth.example.test/application/o/token/" "token endpoint"
  assert_contains "$log" "url=https://gw.example.test/graphql" "gateway endpoint"
  assert_not_contains "$log" "vulnara-gw.rso.dev" "no production gateway call"
  assert_not_contains "$log" "theorigamicorporation.com" "no production token call"
  assert_contains "$(cat "$GITHUB_STEP_SUMMARY")" "https://app.example.test/repository-scans/" \
    "scan links use the overridden app-url without a doubled slash"
}

# spec: action-configuration / Requirement: Validate configuration before scanning /
#       Scenario: Missing required input
test_missing_token_aborts_before_any_request() {
  env_set "INPUT_TOKEN" ""
  run_action
  assert_failure "empty token must abort"
  assert_contains "$ERR" "::error::token is required" "error annotation"
  assert_eq "0" "$(request_count)" "no network request was attempted"
}

# spec: action-configuration / Requirement: Validate configuration before scanning /
#       Scenario: Missing required input
test_each_required_input_is_validated() {
  local var msg
  for pair in "INPUT_SERVICE-ACCOUNT:service-account is required" \
              "INPUT_TENANT:tenant is required" \
              "INPUT_SCAN-TOOLS:scan-tools is required"; do
    var="${pair%%:*}"; msg="${pair#*:}"
    default_inputs
    env_set "$var" ""
    run_action
    assert_failure "$var empty must abort"
    assert_contains "$ERR" "::error::$msg" "error for $var"
    assert_eq "0" "$(request_count)" "no request for $var"
  done
}

# spec: action-configuration / Requirement: Validate configuration before scanning /
#       Scenario: Branch cannot be determined
test_branch_cannot_be_determined() {
  env_set "INPUT_BRANCH" ""
  env_unset "GITHUB_REF_NAME"
  run_action
  assert_failure "no branch must abort"
  assert_contains "$ERR" "::error::branch could not be determined" "branch error"
  assert_eq "0" "$(request_count)" "no network request was attempted"
}

# spec: action-configuration / Requirement: Validate configuration before scanning
test_repository_cannot_be_determined() {
  env_set "INPUT_REPOSITORY" ""
  env_unset "GITHUB_REPOSITORY"
  run_action
  assert_failure "no repository must abort"
  assert_contains "$ERR" "::error::repository could not be determined" "repository error"
}

# spec: action-configuration / Requirement: Validate configuration before scanning /
#       Scenario: Invalid fail-on value
test_invalid_fail_on_value_is_rejected() {
  env_set "INPUT_FAIL-ON" "blocker"
  run_action
  assert_failure "invalid fail-on must abort"
  assert_contains "$ERR" "invalid fail-on 'blocker'" "names the bad value"
  assert_contains "$ERR" "none|low|medium|high|critical" "names the accepted values"
  assert_eq "0" "$(request_count)" "no network request was attempted"
}

# spec: action-configuration / Requirement: Validate configuration before scanning /
#       Scenario: Uppercase fail-on value accepted
test_fail_on_is_case_insensitive() {
  env_set "INPUT_FAIL-ON" "HIGH"
  assert_eq "high" "$(prelude_var FAIL_ON)" "fail-on lowercased"
  assert_eq "3" "$(prelude_var FAIL_RANK)" "high threshold rank"
}

# spec: findings-gate-reporting / Requirement: Gate the build on the highest severity
test_fail_on_threshold_ranks() {
  local expected
  for pair in none:99 low:1 medium:2 high:3 critical:4; do
    expected="${pair#*:}"
    env_set "INPUT_FAIL-ON" "${pair%%:*}"
    assert_eq "$expected" "$(prelude_var FAIL_RANK)" "threshold rank for ${pair%%:*}"
  done
}

# spec: findings-gate-reporting / Requirement: Gate the build on the highest severity
test_sev_rank_is_case_insensitive_and_defaults_to_zero() {
  assert_eq "4" "$(prelude_call sev_rank CRITICAL)" "CRITICAL"
  assert_eq "3" "$(prelude_call sev_rank HIGH)"     "HIGH"
  assert_eq "2" "$(prelude_call sev_rank MEDIUM)"   "MEDIUM"
  assert_eq "1" "$(prelude_call sev_rank LOW)"      "LOW"
  assert_eq "4" "$(prelude_call sev_rank critical)" "lowercase critical"
  assert_eq "2" "$(prelude_call sev_rank Medium)"   "mixed case medium"
  assert_eq "0" "$(prelude_call sev_rank INFO)"     "unknown severity"
  assert_eq "0" "$(prelude_call sev_rank '')"       "empty severity"
}

# spec: findings-gate-reporting / Requirement: Collect findings per scan
test_sev_label_renders_display_names() {
  assert_eq "Critical" "$(prelude_call sev_label CRITICAL)" "Critical"
  assert_eq "High"     "$(prelude_call sev_label HIGH)"     "High"
  assert_eq "Medium"   "$(prelude_call sev_label MEDIUM)"   "Medium"
  assert_eq "Low"      "$(prelude_call sev_label LOW)"      "Low"
  assert_eq "none"     "$(prelude_call sev_label NONE)"     "no findings"
  assert_eq "none"     "$(prelude_call sev_label INFO)"     "unknown severity"
}

# spec: scan-orchestration / Requirement: Resolve the requested scan tools
test_scanner_display_maps_internal_names_to_codenames() {
  assert_eq "Ripley" "$(prelude_call scanner_display AEGIS)"          "AEGIS -> Ripley"
  assert_eq "Ripley" "$(prelude_call scanner_display aegis)"          "aegis -> Ripley"
  assert_eq "Bishop" "$(prelude_call scanner_display pdd)"            "pdd -> Bishop"
  assert_eq "Hicks"  "$(prelude_call scanner_display trivy)"          "trivy -> Hicks"
  assert_eq "Ash"    "$(prelude_call scanner_display secret_scanner)" "secret_scanner -> Ash"
  assert_eq "Secret Scanner" "$(prelude_call scanner_display SECRET_SCANNER)" "SECRET_SCANNER passthrough"
  assert_eq "Personal Data Scanner" "$(prelude_call scanner_display personal_data_scanner)" "personal data scanner"
  assert_eq "custom-tool" "$(prelude_call scanner_display custom-tool)" "unmapped name used raw"
}
