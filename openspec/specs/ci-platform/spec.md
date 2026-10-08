# CI Platform

## Purpose
Covers the parts of the action that depend on the CI system it runs in: detecting that system,
taking the default branch and repository from it, writing errors, warnings and log groups in its
syntax, and publishing the outputs and the summary where it expects them. Everything else in
the action is plain Bash and runs wherever the image runs, so one image serves every platform.
GitHub and GitLab are supported.

## Requirements
### Requirement: Detect the CI platform
The system SHALL determine the CI platform before reading any other input, taking the
`ci-platform` input when it is set and otherwise detecting it from the environment in this
order: `github` when `GITHUB_ACTIONS` is `true`; `gitlab` when `GITLAB_CI` is `true`; and
`none` otherwise. A `ci-platform` value outside `github`, `gitlab` and `none` SHALL fail the run
before any network call. The detected platform SHALL be printed in the run banner.

#### Scenario: Running in GitHub Actions
- **WHEN** `GITHUB_ACTIONS=true`
- **THEN** the platform is `github`

#### Scenario: Running in GitLab CI
- **WHEN** `GITLAB_CI=true` and `GITHUB_ACTIONS` is unset
- **THEN** the platform is `gitlab`

#### Scenario: Running outside any CI
- **WHEN** neither detection variable is set and `ci-platform` is empty
- **THEN** the platform is `none`

#### Scenario: Detection overridden
- **WHEN** `ci-platform` is `gitlab` and `GITHUB_ACTIONS=true`
- **THEN** the platform is `gitlab`

#### Scenario: Unknown platform requested
- **WHEN** `ci-platform` is `jenkins`
- **THEN** the run fails before any network call with a message listing the accepted values

### Requirement: Default the branch and repository from the platform
The system SHALL default an empty `branch` and an empty `repository` from the detected
platform's own variables:

| Platform | `branch` | `repository` |
|---|---|---|
| `github` | `GITHUB_REF_NAME` | `GITHUB_REPOSITORY` |
| `gitlab` | `CI_MERGE_REQUEST_SOURCE_BRANCH_NAME`, else `CI_COMMIT_BRANCH` | `CI_PROJECT_PATH` |
| `none` | none | none |

An input that is set always wins over these defaults.

#### Scenario: GitLab merge request pipeline
- **WHEN** the platform is `gitlab`, `CI_MERGE_REQUEST_SOURCE_BRANCH_NAME=feature/x`,
  `CI_COMMIT_BRANCH` is unset and `CI_PROJECT_PATH=acme/platform/widgets`
- **THEN** the action scans branch `feature/x` of `acme/platform/widgets`

#### Scenario: GitLab branch pipeline
- **WHEN** the platform is `gitlab`, `CI_COMMIT_BRANCH=main` and `CI_PROJECT_PATH=acme/widgets`
- **THEN** the action scans branch `main` of `acme/widgets`

#### Scenario: GitLab tag pipeline
- **WHEN** the platform is `gitlab` and neither branch variable is set
- **THEN** a run with `scan-tools` fails with `branch could not be determined`

#### Scenario: Explicit input wins
- **WHEN** the platform is `gitlab`, `CI_COMMIT_BRANCH=main` and `branch` is `release`
- **THEN** the action scans branch `release`

### Requirement: Emit annotations and log groups in the platform's syntax
The system SHALL render every error annotation, warning annotation and collapsible log group in
the detected platform's syntax:

| Platform | Error | Warning | Group start / end |
|---|---|---|---|
| `github` | `::error::<msg>` | `::warning::<msg>` | `::group::<title>` / `::endgroup::` |
| `gitlab` | `ERROR: <msg>` | `WARNING: <msg>` | collapsible `section_start` / `section_end` markers |
| `none` | `ERROR: <msg>` | `WARNING: <msg>` | the title as a plain line / nothing |

On `gitlab` a group SHALL open with `\e[0Ksection_start:<unix time>:<id>[collapsed=true]\r\e[0K<title>`
and close with `\e[0Ksection_end:<unix time>:<id>\r\e[0K`, where `<id>` is unique within the run
and contains only letters, digits, `_`, `.` and `-`. Every requirement in other capabilities
that names `::error::` or `::warning::` describes the `github` rendering, and SHALL hold on every
other platform with that platform's rendering. The exit status of a failed run SHALL be
non-zero on every platform.

#### Scenario: Warning on GitLab
- **WHEN** the platform is `gitlab` and the repository is private with no `git-token-id`
- **THEN** the log carries `WARNING: repository is private but no git-token-id was provided;
  cloning may fail.` and no `::warning::` line

#### Scenario: Gate failure on GitLab
- **WHEN** the platform is `gitlab` and the gate fails
- **THEN** the log carries `ERROR: scan gate failed: ...` and the process exits non-zero

#### Scenario: Groups collapse on GitLab
- **WHEN** the platform is `gitlab` and the action opens and closes a log group
- **THEN** the log carries a `section_start` and a matching `section_end` marker with the same
  id, and no `::group::` line

#### Scenario: GitHub unchanged
- **WHEN** the platform is `github`
- **THEN** every annotation and group line is byte-identical to the output before this
  requirement

### Requirement: Write outputs and the summary to the platform's sink
The system SHALL publish the run outputs and the Markdown summary through the detected
platform's mechanism:

| Platform | Outputs | Summary |
|---|---|---|
| `github` | append to `GITHUB_OUTPUT` | append to `GITHUB_STEP_SUMMARY` |
| `gitlab` | write `<report-dir>/outputs.env` | write `<report-dir>/summary.md`, and print it in a collapsed log section |
| `none` | write `<report-dir>/outputs.env` when `report-dir` is set | write `<report-dir>/summary.md` when `report-dir` is set |

On `github` the output names SHALL stay the dashed names declared in `action.yml`. Everywhere
else each output SHALL be named `VULNARA_` plus its name upper-cased with dashes replaced by
underscores (`highest-severity` becomes `VULNARA_HIGHEST_SEVERITY`), because a GitLab dotenv
report accepts only that form. `report-dir` SHALL default to `$CI_PROJECT_DIR/.vulnara` on
`gitlab`, and SHALL be created when absent. The summary content SHALL be identical on every
platform.

#### Scenario: GitLab outputs for a dotenv report
- **WHEN** the platform is `gitlab`, `CI_PROJECT_DIR=/builds/acme/widgets` and the gate fails
  with a critical finding
- **THEN** `/builds/acme/widgets/.vulnara/outputs.env` contains
  `VULNARA_HIGHEST_SEVERITY=critical` and `VULNARA_PASSED=false` before the job exits non-zero
- **AND** `/builds/acme/widgets/.vulnara/summary.md` starts with `## ❌ Vulnara scan: Failed`

#### Scenario: GitLab summary in the job log
- **WHEN** the platform is `gitlab` and a run completes
- **THEN** the job log carries the summary inside a collapsed section

#### Scenario: Report directory overridden
- **WHEN** the platform is `gitlab` and `report-dir` is `/tmp/out`
- **THEN** the outputs and summary are written under `/tmp/out` and nothing is written under
  `$CI_PROJECT_DIR/.vulnara`

#### Scenario: Plain container run
- **WHEN** the platform is `none` and `report-dir` is empty
- **THEN** no output file and no summary is written, and the gate decides the exit status as
  before

