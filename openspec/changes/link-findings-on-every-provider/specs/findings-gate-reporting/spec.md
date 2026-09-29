## MODIFIED Requirements

### Requirement: Link findings to source lines
The system SHALL include a detailed findings table when the total finding count is greater
than zero, listing severity, location, tool and confidence for findings that have a `file`,
sorted by descending severity rank and capped at 50 rows. Each location SHALL link to the
file at the scanned commit hash using the provider's path form: `/-/blob/<sha>/` for
`gitlab`, `/src/<sha>/` with a `#lines-<line>` fragment for `bitbucket`,
`?path=/<file>&version=GC<sha>` with `line`, `lineEnd`, `lineStartColumn` and `lineEndColumn`
parameters for `azure_devops`, `/src/commit/<sha>/` for `forgejo`, and `/blob/<sha>/`
otherwise, with a `#L<line>` fragment when a line is known unless the provider form says
otherwise.

#### Scenario: Located finding with a commit hash
- **WHEN** a finding has a `file`, a `line` and a `commitScan.commitHash`, and the repository
  URL was resolved
- **THEN** the location cell is a Markdown link to `<repo url>/blob/<commit>/<file>#L<line>`

#### Scenario: Located finding on a Bitbucket, Azure DevOps or Forgejo repository
- **WHEN** a located finding with a commit hash belongs to a `bitbucket`, `azure_devops` or
  `forgejo` repository
- **THEN** the location links to `<repo url>/src/<commit>/<file>#lines-<line>`,
  `<repo url>?path=/<file>&version=GC<commit>&line=<line>&lineEnd=<line>&lineStartColumn=1&lineEndColumn=1`
  or `<repo url>/src/commit/<commit>/<file>#L<line>` respectively

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
