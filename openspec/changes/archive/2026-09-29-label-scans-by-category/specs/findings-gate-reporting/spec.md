## MODIFIED Requirements

### Requirement: Render the job summary
The system SHALL append a Markdown summary to the file named by `GITHUB_STEP_SUMMARY` when it
is set, containing a pass/fail heading, a table of repository, provider, visibility, branch,
languages, gate setting, highest severity and total duration, a severity count table, and a
per-scan table headed `Category`, carrying the category label each scan covered, its duration,
its finding count and a link to `<app-url>/repository-scans/<scan result id>`.

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
- **WHEN** `GITHUB_STEP_SUMMARY` is not set
- **THEN** no summary is rendered and the run otherwise behaves identically

### Requirement: Link findings to source lines
The system SHALL include a detailed findings table when the total finding count is greater
than zero, listing severity, location, the category label of the scan that reported the finding,
and confidence, for findings that have a `file`, sorted by descending severity rank and capped at
50 rows. Each location SHALL link to the file at the scanned commit hash using the `/-/blob/` path
form for `gitlab` providers and `/blob/` otherwise, with a `#L<line>` fragment when a line is
known.

#### Scenario: Located finding with a commit hash
- **WHEN** a finding has a `file`, a `line` and a `commitScan.commitHash`, and the repository
  URL was resolved
- **THEN** the location cell is a Markdown link to `<repo url>/blob/<commit>/<file>#L<line>`

#### Scenario: Finding without commit or repository URL
- **WHEN** the repository URL is empty or the finding has no commit hash
- **THEN** the location cell is the plain `file:line` text with no link

#### Scenario: Findings without a file are omitted
- **WHEN** a finding has an empty `file`
- **THEN** it is excluded from the detailed table while still counting towards the severity
  totals and the gate

#### Scenario: More than fifty located findings
- **WHEN** more than 50 findings have a file
- **THEN** only the 50 highest-severity rows are rendered
- **AND** a note states how many located findings exist in total and points to the scans
