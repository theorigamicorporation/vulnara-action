#!/usr/bin/env bash
# Tests for the findings-gate-reporting capability.
# Source: openspec/specs/findings-gate-reporting/spec.md

# --- helpers ---------------------------------------------------------------

# findings_fixture <file> <severity> [severity...] : canned scanFindings response
# with one located finding per severity.
findings_fixture() {
  local target="$1"; shift
  local sevs=""
  for s in "$@"; do sevs="$sevs $s"; done
  # shellcheck disable=SC2086
  jq -n --arg sevs "$sevs" '
    {data: {scanFindings: {items:
      ($sevs | ltrimstr(" ") | split(" ") | to_entries | map({
        id: ("finding-" + (.key|tostring)),
        severity: .value,
        file: ("src/app-" + (.key|tostring) + ".go"),
        line: (10 + .key),
        confidence: "HIGH",
        commitScan: {commitHash: "0123456789abcdef0123456789abcdef01234567"}
      }))
    }}}' > "$FIXTURE_DIR/$target"
}

# detailed_rows : only the rows of the "Detailed findings" table
detailed_rows() {
  summary | awk '/^### Detailed findings$/{d=1;next} d && /^\| /{print}' | grep -v '^| Severity |' | grep -v '^|---'
}

use_github_files() {
  export GITHUB_OUTPUT="$WORKDIR/github_output"
  export GITHUB_STEP_SUMMARY="$WORKDIR/summary.md"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"
  env_set "GITHUB_OUTPUT" "$GITHUB_OUTPUT"
  env_set "GITHUB_STEP_SUMMARY" "$GITHUB_STEP_SUMMARY"
}

# --- collecting findings ---------------------------------------------------

# spec: findings-gate-reporting / Requirement: Collect findings per scan /
#       Scenario: Findings aggregated across scans
test_findings_are_aggregated_across_scans() {
  env_set "INPUT_SCAN-TOOLS" "AEGIS,trivy"
  env_set "INPUT_FAIL-ON" "none"
  use_github_files
  findings_fixture scanFindings.1.json CRITICAL HIGH LOW
  findings_fixture scanFindings.2.json MEDIUM medium HIGH
  run_action
  assert_success
  assert_info "Critical" "1" "critical total"
  assert_info "High"     "2" "high total"
  assert_info "Medium"   "2" "medium total (severity compared case-insensitively)"
  assert_info "Low"      "1" "low total"
  assert_info "Total"    "6" "combined total"
  assert_info "Highest"  "Critical" "highest severity"
  local s; s="$(summary)"
  assert_contains "$s" "| 1 | 2 | 2 | 1 | 6 |" "severity count table"
  assert_contains "$s" "| Ripley | " "per-scan row for the first tool"
  assert_contains "$s" "| Hicks | " "per-scan row for the second tool"
  assert_contains "$(graphql_body_for scanFindings)" '"field":"scanResultId"' "findings filtered per scan result"
  assert_contains "$(graphql_body_for scanFindings)" '"stringEquals":"scan-aaaaaaaa-0001"' "first scan result id"
  assert_contains "$(graphql_body_for scanFindings)" '"stringEquals":"scan-bbbbbbbb-0002"' "second scan result id"
}

# spec: findings-gate-reporting / Requirement: Collect findings per scan /
#       Scenario: Scan with no findings
test_scan_without_findings_contributes_nothing() {
  env_set "INPUT_SCAN-TOOLS" "AEGIS,trivy"
  env_set "INPUT_FAIL-ON" "none"
  use_github_files
  findings_fixture scanFindings.1.json HIGH
  fixture scanFindings.2.json <<'J'
{"data":{"scanFindings":{"items":[]}}}
J
  run_action
  assert_success
  assert_info "Total" "1" "only the first scan contributed"
  local s; s="$(summary)"
  assert_contains "$s" "| Hicks | 0s | 0 |" "empty scan reports zero findings"
}

# spec: findings-gate-reporting / Requirement: Collect findings per scan /
#       Scenario: Unrecognised severity value
test_unrecognised_severity_is_ranked_zero_and_not_counted() {
  env_set "INPUT_FAIL-ON" "low"
  use_github_files
  findings_fixture scanFindings.json INFO INFORMATIONAL
  run_action
  assert_success "unknown severities never reach the gate threshold"
  assert_info "Critical" "0" "critical total"
  assert_info "High"     "0" "high total"
  assert_info "Medium"   "0" "medium total"
  assert_info "Low"      "0" "low total"
  assert_info "Total"    "0" "unknown severities are excluded from the totals"
  assert_info "Highest"  "none" "unknown severities rank 0"
}

# --- the gate --------------------------------------------------------------

# spec: findings-gate-reporting / Requirement: Gate the build on the highest severity /
#       Scenario: Findings meet the threshold
test_gate_fails_when_findings_meet_the_threshold() {
  env_set "INPUT_FAIL-ON" "high"
  use_github_files
  findings_fixture scanFindings.json CRITICAL LOW
  run_action
  assert_failure "a critical finding must fail a fail-on high gate"
  assert_contains "$ERR" "::error::scan gate failed: highest severity 'Critical' meets/exceeds fail-on 'high'" \
    "gate failure annotation"
  assert_contains "$(outputs)" "passed=false" "outputs record the failure"
}

# spec: findings-gate-reporting / Requirement: Gate the build on the highest severity
test_gate_fails_when_the_severity_equals_the_threshold() {
  env_set "INPUT_FAIL-ON" "medium"
  use_github_files
  findings_fixture scanFindings.json MEDIUM
  run_action
  assert_failure "an equal severity meets the threshold"
  assert_contains "$ERR" "highest severity 'Medium' meets/exceeds fail-on 'medium'" "gate failure annotation"
}

# spec: findings-gate-reporting / Requirement: Gate the build on the highest severity /
#       Scenario: Findings below the threshold
test_gate_passes_when_findings_are_below_the_threshold() {
  env_set "INPUT_FAIL-ON" "high"
  use_github_files
  findings_fixture scanFindings.json MEDIUM LOW
  run_action
  assert_success "a medium finding must not fail a fail-on high gate"
  assert_contains "$ERR" "scan gate passed (fail-on: high, highest: Medium)" "gate pass log"
  assert_contains "$(outputs)" "passed=true" "outputs record the pass"
}

# spec: findings-gate-reporting / Requirement: Gate the build on the highest severity /
#       Scenario: Gate disabled
test_gate_disabled_passes_with_critical_findings() {
  env_set "INPUT_FAIL-ON" "none"
  use_github_files
  findings_fixture scanFindings.json CRITICAL CRITICAL
  run_action
  assert_success "fail-on none never fails the build"
  assert_contains "$(outputs)" "passed=true" "outputs record the pass"
  assert_contains "$(outputs)" "highest-severity=critical" "the highest severity is still reported"
}

# spec: findings-gate-reporting / Requirement: Gate the build on the highest severity /
#       Scenario: No findings at all
test_no_findings_reports_none_and_passes() {
  env_set "INPUT_FAIL-ON" "low"
  use_github_files
  run_action
  assert_success "an empty scan passes every gate"
  assert_info "Highest" "none" "highest severity is none"
  assert_contains "$(outputs)" "highest-severity=none" "output is none"
  assert_contains "$(summary)" "| Highest severity | **none** |" "summary reports none"
}

# spec: findings-gate-reporting / Requirement: Gate the build on the highest severity
test_lowest_threshold_fails_on_a_low_finding() {
  env_set "INPUT_FAIL-ON" "low"
  use_github_files
  findings_fixture scanFindings.json LOW
  run_action
  assert_failure "fail-on low must fail on a low finding"
  assert_contains "$ERR" "highest severity 'Low' meets/exceeds fail-on 'low'" "gate failure annotation"
}

# --- outputs ---------------------------------------------------------------

# spec: findings-gate-reporting / Requirement: Publish action outputs /
#       Scenario: Outputs written for a failing gate
test_outputs_are_written_before_a_failing_exit() {
  env_set "INPUT_SCAN-TOOLS" "AEGIS,trivy"
  env_set "INPUT_FAIL-ON" "critical"
  use_github_files
  findings_fixture scanFindings.1.json CRITICAL
  findings_fixture scanFindings.2.json LOW
  run_action
  assert_failure "the gate fails"
  local o; o="$(outputs)"
  assert_contains "$o" "scan-result-ids=scan-aaaaaaaa-0001 scan-bbbbbbbb-0002" "space-separated scan ids"
  assert_contains "$o" "highest-severity=critical" "lowercased highest severity"
  assert_contains "$o" "passed=false" "gate verdict"
}

# spec: findings-gate-reporting / Requirement: Publish action outputs /
#       Scenario: GITHUB_OUTPUT unavailable
test_missing_github_output_is_tolerated() {
  env_set "INPUT_FAIL-ON" "none"
  env_unset "GITHUB_OUTPUT"
  findings_fixture scanFindings.json HIGH
  run_action
  assert_success "the run completes without GITHUB_OUTPUT"
  assert_info "Highest" "High" "the gate decision is still made"
  assert_contains "$ERR" "scan gate passed" "gate still evaluated"
}

# spec: findings-gate-reporting / Requirement: Publish action outputs /
#       Scenario: GITHUB_OUTPUT unavailable
test_missing_github_output_still_fails_the_gate() {
  env_set "INPUT_FAIL-ON" "critical"
  env_unset "GITHUB_OUTPUT"
  findings_fixture scanFindings.json CRITICAL
  run_action
  assert_failure "the gate still fails without GITHUB_OUTPUT"
  assert_contains "$ERR" "scan gate failed" "gate failure annotation"
}

# --- job summary -----------------------------------------------------------

# spec: findings-gate-reporting / Requirement: Render the job summary /
#       Scenario: Summary written after a scan run
test_summary_is_rendered_for_a_passing_run() {
  env_set "INPUT_FAIL-ON" "critical"
  use_github_files
  findings_fixture scanFindings.json MEDIUM
  run_action
  assert_success
  local s; s="$(summary)"
  assert_contains "$s" "## ✅ Vulnara scan: Passed" "pass heading"
  assert_contains "$s" "| Repository | [\`acme/widgets\`](https://git.example.test/acme/widgets) |" "linked repository cell"
  assert_contains "$s" "| Provider | github (public) |" "provider and visibility"
  assert_contains "$s" "| Branch | \`feature/x\` |" "branch"
  assert_contains "$s" "| Languages | Go, Shell |" "languages"
  assert_contains "$s" "| Gate | \`fail-on: critical\` |" "gate setting"
  assert_contains "$s" "| Highest severity | **Medium** |" "highest severity"
  assert_contains "$s" "| Duration |" "total duration"
  assert_contains "$s" "### Findings" "severity section"
  assert_contains "$s" "### Scans" "scans section"
  assert_contains "$s" "[\`scan-aaa\`](https://app.example.test/repository-scans/scan-aaaaaaaa-0001)" "scan link"
}

# spec: findings-gate-reporting / Requirement: Render the job summary /
#       Scenario: Summary written after a scan run
test_summary_heading_reports_a_failed_gate() {
  env_set "INPUT_FAIL-ON" "medium"
  use_github_files
  findings_fixture scanFindings.json HIGH
  run_action
  assert_failure
  assert_contains "$(summary)" "## ❌ Vulnara scan: Failed" "fail heading"
}

# spec: findings-gate-reporting / Requirement: Render the job summary /
#       Scenario: Summary written after a scan run
test_summary_repository_cell_is_plain_without_a_url() {
  use_github_files
  fixture repositories.json <<'J'
{"data":{"repositories":{"items":[
  {"id":"repo-1111","repositoryName":"widgets","private":false,"enabled":true,
   "programmingLanguage":["Go"],"cloneUrl":null,
   "gitEntity":{"__typename":"Organization","name":"acme","gitType":"github","htmlUrl":null}}
]}}}
J
  run_action
  assert_success
  local s; s="$(summary)"
  assert_contains "$s" "| Repository | \`acme/widgets\` |" "plain code repository cell"
  assert_not_contains "$s" "[\`acme/widgets\`](" "no link when no url was resolved"
}

# spec: findings-gate-reporting / Requirement: Render the job summary /
#       Scenario: Summary unavailable
test_missing_step_summary_is_tolerated() {
  env_set "INPUT_FAIL-ON" "none"
  env_unset "GITHUB_STEP_SUMMARY"
  export GITHUB_OUTPUT="$WORKDIR/github_output"
  env_set "GITHUB_OUTPUT" "$GITHUB_OUTPUT"
  findings_fixture scanFindings.json CRITICAL
  run_action
  assert_success "the run completes without GITHUB_STEP_SUMMARY"
  assert_contains "$(outputs)" "highest-severity=critical" "outputs are still written"
}

# --- detailed findings table ----------------------------------------------

# spec: findings-gate-reporting / Requirement: Link findings to source lines /
#       Scenario: Located finding with a commit hash
test_located_findings_link_to_the_scanned_commit() {
  env_set "INPUT_FAIL-ON" "none"
  use_github_files
  findings_fixture scanFindings.json HIGH
  run_action
  assert_success
  local s; s="$(summary)"
  assert_contains "$s" "### Detailed findings" "detailed section"
  assert_contains "$s" "| High | [\`src/app-0.go:10\`](https://git.example.test/acme/widgets/blob/0123456789abcdef0123456789abcdef01234567/src/app-0.go#L10) | Ripley | HIGH |" \
    "linked location, tool and confidence"
}

# spec: findings-gate-reporting / Requirement: Link findings to source lines /
#       Scenario: Located finding with a commit hash
test_gitlab_repositories_use_the_dash_blob_path() {
  env_set "INPUT_FAIL-ON" "none"
  use_github_files
  fixture repositories.json <<'J'
{"data":{"repositories":{"items":[
  {"id":"repo-1111","repositoryName":"widgets","private":false,"enabled":true,
   "programmingLanguage":["Go"],"cloneUrl":"https://git.example.test/acme/widgets.git",
   "gitEntity":{"__typename":"Organization","name":"acme","gitType":"gitlab","htmlUrl":"https://git.example.test/acme"}}
]}}}
J
  findings_fixture scanFindings.json HIGH
  run_action
  assert_success
  assert_contains "$(summary)" "https://git.example.test/acme/widgets/-/blob/0123456789abcdef0123456789abcdef01234567/src/app-0.go#L10" \
    "gitlab blob path"
}

# spec: findings-gate-reporting / Requirement: Link findings to source lines /
#       Scenario: Finding without commit or repository URL
test_finding_without_a_commit_hash_is_not_linked() {
  env_set "INPUT_FAIL-ON" "none"
  use_github_files
  fixture scanFindings.json <<'J'
{"data":{"scanFindings":{"items":[
  {"id":"f1","severity":"HIGH","file":"src/app.go","line":42,"confidence":"MEDIUM","commitScan":null}
]}}}
J
  run_action
  assert_success
  local s; s="$(summary)"
  assert_contains "$s" "| High | src/app.go:42 | Ripley | MEDIUM |" "plain location text"
  assert_not_contains "$s" "/blob/" "no blob link without a commit hash"
}

# spec: findings-gate-reporting / Requirement: Link findings to source lines /
#       Scenario: Finding without commit or repository URL
test_finding_is_not_linked_when_the_repository_url_is_unknown() {
  env_set "INPUT_FAIL-ON" "none"
  use_github_files
  fixture repositories.json <<'J'
{"data":{"repositories":{"items":[
  {"id":"repo-1111","repositoryName":"widgets","private":false,"enabled":true,
   "programmingLanguage":["Go"],"cloneUrl":null,
   "gitEntity":{"__typename":"Organization","name":"acme","gitType":"github","htmlUrl":null}}
]}}}
J
  findings_fixture scanFindings.json HIGH
  run_action
  assert_success
  assert_contains "$(summary)" "| High | src/app-0.go:10 | Ripley | HIGH |" "plain location text"
}

# spec: findings-gate-reporting / Requirement: Link findings to source lines
test_finding_without_a_line_omits_the_line_fragment() {
  env_set "INPUT_FAIL-ON" "none"
  use_github_files
  fixture scanFindings.json <<'J'
{"data":{"scanFindings":{"items":[
  {"id":"f1","severity":"LOW","file":"src/app.go","line":null,"confidence":null,
   "commitScan":{"commitHash":"abcdef1234567890abcdef1234567890abcdef12"}}
]}}}
J
  run_action
  assert_success
  local s; s="$(summary)"
  assert_contains "$s" "[\`src/app.go\`](https://git.example.test/acme/widgets/blob/abcdef1234567890abcdef1234567890abcdef12/src/app.go)" \
    "no #L fragment"
  assert_contains "$s" "| Ripley | - |" "missing confidence rendered as a dash"
}

# spec: findings-gate-reporting / Requirement: Link findings to source lines /
#       Scenario: Findings without a file are omitted
test_findings_without_a_file_are_counted_but_not_listed() {
  env_set "INPUT_FAIL-ON" "none"
  use_github_files
  fixture scanFindings.json <<'J'
{"data":{"scanFindings":{"items":[
  {"id":"f1","severity":"CRITICAL","file":"","line":null,"confidence":"HIGH","commitScan":null},
  {"id":"f2","severity":"LOW","file":"src/app.go","line":7,"confidence":"LOW","commitScan":null}
]}}}
J
  run_action
  assert_success
  assert_info "Critical" "1" "the file-less finding still counts"
  assert_info "Total" "2" "both findings counted"
  assert_info "Highest" "Critical" "the file-less finding still drives the highest severity"
  local rows; rows="$(detailed_rows)"
  assert_contains "$rows" "| Low | src/app.go:7 |" "located finding is listed"
  assert_not_contains "$rows" "| Critical |" "the file-less finding is not listed in the detailed table"
  assert_eq "1" "$(printf '%s\n' "$rows" | grep -c .)" "exactly one detailed row"
}

# spec: findings-gate-reporting / Requirement: Link findings to source lines
test_detailed_table_is_sorted_by_descending_severity() {
  env_set "INPUT_FAIL-ON" "none"
  use_github_files
  findings_fixture scanFindings.json LOW CRITICAL MEDIUM HIGH
  run_action
  assert_success
  local order
  order="$(detailed_rows | cut -d'|' -f2 | tr -d ' ' | tr '\n' ' ')"
  assert_eq "Critical High Medium Low " "$order" "rows ordered by descending severity rank"
}

# spec: findings-gate-reporting / Requirement: Link findings to source lines /
#       Scenario: More than fifty located findings
test_detailed_table_is_capped_at_fifty_rows() {
  env_set "INPUT_FAIL-ON" "none"
  use_github_files
  jq -n '{data:{scanFindings:{items:
    [range(0;55) | {id:("f"+(.|tostring)), severity:"LOW", file:("src/f"+(.|tostring)+".go"),
                    line:1, confidence:"LOW", commitScan:{commitHash:"abc123"}}]
  }}}' > "$FIXTURE_DIR/scanFindings.json"
  run_action
  assert_success
  local s rows; s="$(summary)"
  rows="$(printf '%s\n' "$s" | grep -c '^| Low |')"
  assert_eq "50" "$rows" "only the first 50 rows are rendered"
  assert_info "Total" "55" "all findings are still counted"
  assert_contains "$s" "_Showing the top 50 of 55 located findings. Open the scans above to see all._" \
    "cap note names both counts"
}

# spec: findings-gate-reporting / Requirement: Link findings to source lines
test_detailed_table_is_omitted_without_findings() {
  env_set "INPUT_FAIL-ON" "none"
  use_github_files
  run_action
  assert_success
  assert_not_contains "$(summary)" "### Detailed findings" "no detailed table when there are no findings"
}
