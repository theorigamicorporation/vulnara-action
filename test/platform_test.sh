#!/usr/bin/env bash
# Tests for the ci-platform capability.
# Source: openspec/specs/ci-platform/spec.md

# --- helpers ---------------------------------------------------------------

# use_gitlab : run as a GitLab CI job with its project checked out under WORKDIR
use_gitlab() {
  env_unset "GITHUB_ACTIONS"
  env_set "GITLAB_CI" "true"
  PROJECT_DIR="$WORKDIR/project"
  mkdir -p "$PROJECT_DIR"
  env_set "CI_PROJECT_DIR" "$PROJECT_DIR"
}

critical_finding() {
  fixture scanFindings.json <<'J'
{"data":{"scanFindings":{"items":[{"id":"finding-0","severity":"CRITICAL","file":"src/app.go","line":10,
 "confidence":"HIGH","commitScan":{"commitHash":"0123456789abcdef0123456789abcdef01234567"}}]}}}
J
}

# --- detection -------------------------------------------------------------

# spec: ci-platform / Requirement: Detect the CI platform /
#       Scenario: Running in GitHub Actions
test_platform_is_github_in_github_actions() {
  assert_eq "github" "$(prelude_var CI_PLATFORM)" "detected platform"
}

# spec: ci-platform / Requirement: Detect the CI platform /
#       Scenario: Running in GitLab CI
test_platform_is_gitlab_in_gitlab_ci() {
  use_gitlab
  assert_eq "gitlab" "$(prelude_var CI_PLATFORM)" "detected platform"
}

# spec: ci-platform / Requirement: Detect the CI platform /
#       Scenario: Running outside any CI
test_platform_is_none_outside_ci() {
  env_unset "GITHUB_ACTIONS"
  assert_eq "none" "$(prelude_var CI_PLATFORM)" "detected platform"
}

# spec: ci-platform / Requirement: Detect the CI platform /
#       Scenario: Detection overridden
test_ci_platform_input_overrides_detection() {
  env_set "INPUT_CI-PLATFORM" "gitlab"
  assert_eq "gitlab" "$(prelude_var CI_PLATFORM)" "overridden platform"
}

# spec: ci-platform / Requirement: Detect the CI platform /
#       Scenario: Unknown platform requested
test_unknown_ci_platform_fails_before_any_request() {
  env_set "INPUT_CI-PLATFORM" "jenkins"
  run_action
  assert_failure
  assert_contains "$ERR" "invalid ci-platform 'jenkins' (expected github|gitlab|none)" "failure lists the accepted values"
  assert_eq "0" "$(request_count)" "no network call"
}

# spec: ci-platform / Requirement: Detect the CI platform /
#       Scenario: Running in GitLab CI
test_platform_is_printed_in_the_banner() {
  use_gitlab
  run_action
  assert_success
  assert_contains "$ERR" "vulnara: CI platform: gitlab" "banner names the platform"
}

# --- branch and repository defaults ---------------------------------------

# spec: ci-platform / Requirement: Default the branch and repository from the platform /
#       Scenario: GitLab merge request pipeline
test_gitlab_merge_request_defaults() {
  use_gitlab
  env_set "INPUT_BRANCH" ""
  env_set "INPUT_REPOSITORY" ""
  env_set "CI_MERGE_REQUEST_SOURCE_BRANCH_NAME" "feature/x"
  env_set "CI_PROJECT_PATH" "acme/platform/widgets"
  assert_eq "feature/x" "$(prelude_var BRANCH)" "branch from the merge request source branch"
  assert_eq "acme/platform/widgets" "$(prelude_var REPOSITORY)" "repository from CI_PROJECT_PATH"
}

# spec: ci-platform / Requirement: Default the branch and repository from the platform /
#       Scenario: GitLab branch pipeline
test_gitlab_branch_pipeline_defaults() {
  use_gitlab
  env_set "INPUT_BRANCH" ""
  env_set "INPUT_REPOSITORY" ""
  env_set "CI_COMMIT_BRANCH" "main"
  env_set "CI_PROJECT_PATH" "acme/widgets"
  assert_eq "main" "$(prelude_var BRANCH)" "branch from CI_COMMIT_BRANCH"
  assert_eq "acme/widgets" "$(prelude_var REPOSITORY)" "repository from CI_PROJECT_PATH"
}

# spec: ci-platform / Requirement: Default the branch and repository from the platform /
#       Scenario: GitLab tag pipeline
test_gitlab_tag_pipeline_has_no_branch() {
  use_gitlab
  env_set "INPUT_BRANCH" ""
  env_set "CI_PROJECT_PATH" "acme/widgets"
  run_action
  assert_failure
  assert_contains "$ERR" "ERROR: branch could not be determined" "tag pipelines have no branch"
}

# spec: ci-platform / Requirement: Default the branch and repository from the platform /
#       Scenario: Explicit input wins
test_explicit_branch_wins_over_gitlab_variables() {
  use_gitlab
  env_set "INPUT_BRANCH" "release"
  env_set "CI_COMMIT_BRANCH" "main"
  assert_eq "release" "$(prelude_var BRANCH)" "explicit branch input"
}

# spec: ci-platform / Requirement: Default the branch and repository from the platform /
#       Scenario: GitLab branch pipeline
test_github_variables_are_ignored_on_gitlab() {
  use_gitlab
  env_set "INPUT_BRANCH" ""
  env_set "GITHUB_REF_NAME" "from-github"
  assert_eq "" "$(prelude_var BRANCH)" "GITHUB_REF_NAME is not a GitLab default"
}

# --- annotations and groups -----------------------------------------------

# spec: ci-platform / Requirement: Emit annotations and log groups in the platform's syntax /
#       Scenario: Warning on GitLab
test_gitlab_warning_is_a_plain_line() {
  use_gitlab
  local private; private="$(jq '.data.repositories.items[0].private = true' "$FIXTURE_DIR/repositories.json")"
  fixture repositories.json <<< "$private"
  run_action
  assert_success
  assert_contains "$ERR" "WARNING: repository is private but no git-token-id was provided; cloning may fail." "GitLab warning"
  assert_not_contains "$ERR" "::warning::" "no GitHub annotation"
}

# spec: ci-platform / Requirement: Emit annotations and log groups in the platform's syntax /
#       Scenario: Gate failure on GitLab
test_gitlab_gate_failure_is_a_plain_error() {
  use_gitlab
  critical_finding
  run_action
  assert_failure
  assert_contains "$ERR" "ERROR: scan gate failed: highest severity 'Critical'" "GitLab error"
  assert_not_contains "$ERR" "::error::" "no GitHub annotation"
}

# spec: ci-platform / Requirement: Emit annotations and log groups in the platform's syntax /
#       Scenario: Groups collapse on GitLab
test_gitlab_groups_are_collapsible_sections() {
  use_gitlab
  local log; log="$(prelude_call '{ group "Details"; endgroup; } 2>&1')"
  local esc=$'\e' cr=$'\r'
  assert_contains "$log" "${esc}[0Ksection_start:" "section start marker"
  local id; id="$(printf '%s' "$log" | sed -n 's/.*section_start:[0-9]*:\([A-Za-z0-9_.-]*\)\[collapsed=true\].*Details.*/\1/p' | tail -1)"
  [ -n "$id" ] || _fail_assert "collapsed section titled Details with a valid id"
  assert_contains "$log" ":${id}[collapsed=true]${cr}${esc}[0KDetails" "collapsed section with its title"
  assert_contains "$log" "${esc}[0Ksection_end:" "section end marker"
  assert_contains "$log" ":${id}${cr}${esc}[0K" "end marker matches the start id"
  assert_not_contains "$log" "::group::" "no GitHub group"
}

# spec: ci-platform / Requirement: Emit annotations and log groups in the platform's syntax /
#       Scenario: GitHub unchanged
test_github_annotations_and_groups_are_unchanged() {
  assert_eq $'::group::Details\n::endgroup::\n::warning::careful' \
    "$(prelude_call '{ group "Details"; endgroup; warn "careful"; } 2>&1')" "GitHub syntax"
  assert_eq "::error::stop" "$(prelude_call '( fail "stop" ) 2>&1')" "GitHub error annotation"
}

# --- outputs and summary --------------------------------------------------

# spec: ci-platform / Requirement: Write outputs and the summary to the platform's sink /
#       Scenario: GitLab outputs for a dotenv report
test_gitlab_outputs_and_summary_go_to_the_report_dir() {
  use_gitlab
  critical_finding
  run_action
  assert_failure
  local env_file="$PROJECT_DIR/.vulnara/outputs.env"
  assert_contains "$(cat "$env_file")" "VULNARA_HIGHEST_SEVERITY=critical" "dotenv highest severity"
  assert_contains "$(cat "$env_file")" "VULNARA_PASSED=false" "dotenv pass flag"
  assert_contains "$(cat "$env_file")" "VULNARA_SCAN_RESULT_IDS=scan-aaaaaaaa-0001" "dotenv scan result ids"
  assert_eq "" "$(grep -vE '^VULNARA_[A-Z0-9_]+=' "$env_file")" "every line is a valid dotenv variable"
  assert_eq "## ❌ Vulnara scan: Failed" "$(head -1 "$PROJECT_DIR/.vulnara/summary.md")" "summary heading"
}

# spec: ci-platform / Requirement: Write outputs and the summary to the platform's sink /
#       Scenario: GitLab summary in the job log
test_gitlab_summary_is_printed_in_a_collapsed_section() {
  use_gitlab
  run_action
  assert_success
  assert_contains "$ERR" "[collapsed=true]" "collapsed section"
  assert_contains "$ERR" "## ✅ Vulnara scan: Passed" "summary in the log"
}

# spec: ci-platform / Requirement: Write outputs and the summary to the platform's sink /
#       Scenario: Report directory overridden
test_report_dir_input_overrides_the_default() {
  use_gitlab
  env_set "INPUT_REPORT-DIR" "$WORKDIR/out"
  run_action
  assert_success
  assert_contains "$(cat "$WORKDIR/out/outputs.env")" "VULNARA_PASSED=true" "outputs under report-dir"
  [ -f "$WORKDIR/out/summary.md" ] || _fail_assert "summary.md under report-dir"
  [ ! -e "$PROJECT_DIR/.vulnara" ] || _fail_assert "nothing written under CI_PROJECT_DIR/.vulnara"
}

# spec: ci-platform / Requirement: Write outputs and the summary to the platform's sink /
#       Scenario: Plain container run
test_plain_run_writes_no_files() {
  env_unset "GITHUB_ACTIONS"
  run_action
  assert_success
  assert_eq "" "$(find "$WORKDIR" \( -name outputs.env -o -name summary.md \) -print)" "no output or summary file"
  assert_contains "$ERR" "scan gate passed" "the gate still decides"
}

# spec: ci-platform / Requirement: Write outputs and the summary to the platform's sink /
#       Scenario: Plain container run
test_plain_run_with_report_dir_writes_files() {
  env_unset "GITHUB_ACTIONS"
  env_set "INPUT_REPORT-DIR" "$WORKDIR/out"
  run_action
  assert_success
  assert_contains "$(cat "$WORKDIR/out/outputs.env")" "VULNARA_PASSED=true" "outputs under report-dir"
}

# spec: runtime-safety / Requirement: Credentials never reach a persisted surface /
#       Scenario: Successful run on a file-sink platform
test_gitlab_report_files_carry_no_credential() {
  use_gitlab
  run_action
  assert_success
  local files; files="$(cat "$PROJECT_DIR/.vulnara/outputs.env" "$PROJECT_DIR/.vulnara/summary.md")"
  assert_not_contains "$files" "not-a-real-token" "token input"
  assert_not_contains "$files" "test-jwt-value" "JWT"
}
