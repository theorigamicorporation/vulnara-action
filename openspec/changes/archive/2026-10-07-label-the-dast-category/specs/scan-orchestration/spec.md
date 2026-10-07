## MODIFIED Requirements

### Requirement: Never identify a scanner to the caller
The action SHALL NOT write anything that identifies a scanner to the console log, to a GitHub
annotation, to the job summary or to an action output: not the stored `dockerScanTools` name, not
a codename or product name derived from it, and not an enumeration of the catalogue. A workflow
log is world-readable on a public repository, and what ran a scan is not a customer-facing fact.

A scan SHALL be labelled by the category it covers. The labels are fixed: `sast` is
`Code analysis`, `sca` is `Dependencies`, `secrets` is `Secrets`, `pii` is `Personal data`,
`dast` is `Web application`. The wire value SHALL be matched case-insensitively. `dast` is labelled
even though no scanner serves it yet, so the first scan covering it is not shown as
`Uncategorised`.

A scanner serves one or more categories, so a label MAY be a set. It SHALL be joined and
deduplicated, because two categories rendering to the same label would otherwise count the
scanners behind them.

Where no category can be resolved, the label SHALL be `Uncategorised`. That value is display
only: it is never sent to the platform, never filtered on, and is not a category the platform
knows about.

A failure to resolve a requested tool SHALL NOT enumerate the tools that do resolve. The caller
needs to know that what they asked for was rejected, not what else exists.

#### Scenario: A scan is named in the log or the summary
- **WHEN** any line of the console log, the job summary or an annotation refers to a scan
- **THEN** it names the category the scan covers
- **AND** no scanner name, codename or product name appears in that line

#### Scenario: A scanner serving two categories
- **WHEN** a resolved tool records both `sca` and `secrets`
- **THEN** the scan is labelled `Dependencies, Secrets`
- **AND** a tool recording the same category twice is labelled once, so the label does not
  disclose how many scanners ran

#### Scenario: A scanner serving the web application category
- **WHEN** a resolved tool records `dast`, in any casing
- **THEN** the scan is labelled `Web application`
- **AND** a tool recording `sca` and `dast` is labelled `Dependencies, Web application`

#### Scenario: A scanner whose categories cannot be resolved
- **WHEN** a resolved tool records no category, or the gateway exposes no categories at all
- **THEN** the scan is labelled `Uncategorised`
- **AND** the tool's stored name appears in no log line, annotation, summary row or output
