## MODIFIED Requirements

### Requirement: Publish action outputs
The system SHALL publish `scan-result-ids`, `highest-severity` and `passed` through the
detected CI platform's output sink, as the `ci-platform` capability specifies; on GitHub that
is appending to the file named by `GITHUB_OUTPUT` when it is set. `scan-result-ids` is the
space-separated list of started scan result ids, `highest-severity` is the lowercased highest
severity or `none`, and `passed` is `true` or `false`.

#### Scenario: Outputs written for a failing gate
- **WHEN** the gate fails with a critical finding and `GITHUB_OUTPUT` is set
- **THEN** the file receives `highest-severity=critical` and `passed=false` before the job
  exits non-zero, so downstream steps can read the outputs

#### Scenario: GITHUB_OUTPUT unavailable
- **WHEN** the platform is `github` and `GITHUB_OUTPUT` is not set in the environment
- **THEN** the action skips writing outputs and still completes its gate decision

### Requirement: Render the job summary
The system SHALL publish a Markdown summary through the detected CI platform's summary sink, as
the `ci-platform` capability specifies; on GitHub that is appending to the file named by
`GITHUB_STEP_SUMMARY` when it is set. The summary contains a pass/fail heading, a table of
repository, provider, visibility, branch, languages, gate setting, highest severity and total
duration, a severity count table, and a per-scan table headed `Category`, carrying the category
label each scan covered, its duration, its finding count and a link to
`<app-url>/repository-scans/<scan result id>`.

#### Scenario: Summary written after a scan run
- **WHEN** the scans complete and `GITHUB_STEP_SUMMARY` is set
- **THEN** the summary starts with `## ✅ Vulnara scan: Passed` or `## ❌ Vulnara scan: Failed`
- **AND** the repository cell links to the repository browsing URL when one was resolved,
  and is plain code text otherwise

#### Scenario: Per-scan rows carry no scanner identity
- **WHEN** the per-scan table is rendered
- **THEN** each row's first cell is the category label for that scan
- **AND** no scanner name, codename or product name appears in the summary

#### Scenario: Summary unavailable
- **WHEN** the platform is `github` and `GITHUB_STEP_SUMMARY` is not set
- **THEN** no summary is rendered and the run otherwise behaves identically
