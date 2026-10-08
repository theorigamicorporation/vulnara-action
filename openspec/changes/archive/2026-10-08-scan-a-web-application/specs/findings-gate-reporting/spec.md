## ADDED Requirements

### Requirement: Gate and report web application findings
After a web scan completes, the system SHALL count its `dastFindings` filtered on
`scanResultId` per severity (`CRITICAL`, `HIGH`, `MEDIUM`, `LOW`) from each filtered list's
`total`, add them to the run's severity totals, and apply the same `fail-on` gate, so the
highest severity across repository and web findings decides the outcome. It SHALL write the
`web-target-id` and `web-scan-result-id` outputs when a web scan ran. `scan-result-ids` SHALL
keep listing repository scans only.

The job summary SHALL carry a `Web application` section: the target name and base URL, a link
to `<app-url>/web-targets/<web target id>`, the scan's duration, the findings by severity, and,
when there are any, a table of at most 50 findings sorted by severity with the finding name (or
check id), the matched URL and the CVE and CWE ids. A web-only run SHALL omit the repository
rows of the summary.

#### Scenario: A critical web finding trips the gate
- **WHEN** `fail-on` is `high` and the web scan has one critical finding
- **THEN** the run fails with `scan gate failed: highest severity 'Critical' meets/exceeds fail-on 'high'`
- **AND** `highest-severity=critical` and `passed=false` are written

#### Scenario: Web findings totalled with repository findings
- **WHEN** a run scans a repository with one high finding and a web target with two medium
  findings
- **THEN** the totals are one high and two medium

#### Scenario: Web section in the summary
- **WHEN** a web scan ran and `GITHUB_STEP_SUMMARY` is set
- **THEN** the summary has a `### Web application` section with the target, its link and the
  per-severity counts
- **AND** no scanner name appears in it
