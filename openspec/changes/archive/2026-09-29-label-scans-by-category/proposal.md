## Why

The previous change stopped the action printing a scanner's *stored* name. It left the map that
turns that stored name into a codename, so every successful run still printed `Ripley`, `Bishop`,
`Hicks` or `Ash` on the `tool` line, in `started '<name>'`, in the completion line and in two
columns of the job summary. A workflow log is world-readable on a public repository. The owner
has retired those codenames from customer surfaces entirely, and `vulnara-site` is removing the
only public page that says what `Ripley` is, so a customer would read a codename in their own CI
log with nowhere left to look it up.

The second problem is the query, not the printing. `resolve_tools` selects
`dockerScanTools { id name }` unconditionally. `DockerScanTool.name` is being removed, and
selecting a field the schema no longer has fails the *whole* query with
`GRAPHQL_VALIDATION_FAILED`. Reproduced against a gateway answering that way: the run prints the
validation error, then `::error::GraphQL request failed`, then
`::error::scan tool 'AEGIS' is not available to tenant '...'`, and exits 1 having started nothing.
A `scan-tools` value pinned to an **id** fails identically, because the query dies before any
matching happens. `scan-tools` lives in consumers' own workflow files, so on the day `name` is
removed every pinned workflow breaks at once, and the annotation a customer reads blames their
input for a change made on our side.

## What Changes

- A scan is labelled by the **category** it covers, never by the scanner that ran it. The
  codename map is deleted rather than renamed. The labels are the shared vocabulary: `sast` Code
  analysis, `sca` Dependencies, `secrets` Secrets, `pii` Personal data.
- A scanner serves one or more categories, so a label can be a set. It is joined with commas and
  deduplicated, because a repeated label counts the scanners behind it.
- When no category resolves, the label is `Uncategorised`. Display only: never sent to the
  platform, not a category the platform knows about.
- The `dockerScanTools` selection set is assembled from the fields the schema actually has. A
  field the gateway rejects is identified from the validation error, dropped, and the query
  retried. `name` and `categories` are both optional this way, so the action works against the
  gateway that ships today, against the one that adds `categories`, and against the one that
  removes `name`.
- Matching by id always works. Matching by name works while the gateway still returns one.
- An entry that is not an id, against a gateway that no longer resolves names, fails with a
  message that says so, instead of claiming the tenant cannot run the scanner.
- Any GraphQL error other than a rejected optional field still aborts with the gateway's own
  wording.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `scan-orchestration`: `Never print a scanner's stored name` is replaced by
  `Never identify a scanner to the caller`, which covers the codenames too and fixes the label on
  the category rather than on a mapping of names. `Resolve the requested scan tools` gains the
  adaptive selection set and the id-only guarantee. `Start one scan per tool` and
  `Wait for scans to finish` name the category label instead of a display name.
- `findings-gate-reporting`: the two summary tables carry a `Category` column, not a `Tool` one.

## Impact

- `entrypoint.sh`: `gql` is split into `gql_post` (transport) and `gql` (abort on errors) so a
  recoverable error can be inspected; `scanner_display` is replaced by `category_display` and
  `categories_display`; `scan_tool_catalogue` is new; `resolve_tools` matches on id first and
  emits a category label; the label arrays and both summary column headers are renamed.
- `test/fixtures/base/dockerScanTools.json` grows `categories`.
- `test/config_test.sh`, `test/orchestration_test.sh`, `test/reporting_test.sh`.
- `docs/reference.md`, `docs/architecture.md`, `docs/configuration.md`, `README.md`,
  `openspec/project.md`.
- No change to the inputs, the outputs, the gate, or the shape of the job summary.
- `action.yml` is deliberately unchanged: its `scan-tools` description is copied verbatim into
  `vulnara-site`'s committed `action.json` snapshot by that repository's weekly docs sync, and the
  two already agree.

## Quota

None. The action starts one scan per resolved tool and does not adopt the category-based scan
mutation, so a run costs exactly what it costs today. Adopting `startRepositoryCategoryScan`,
which fans out to every scanner in a category, is separate work and would change what a
customer's quota buys.
