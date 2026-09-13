## ADDED Requirements

### Requirement: Gate checks run in the script's own process
Every check that can fail the run SHALL execute in the process that owns the
script's exit status, and SHALL NOT be placed inside a subshell. The failure
helper aborts by exiting, so an abort raised inside a subshell — a process
substitution, a pipeline stage, a command substitution used as a statement, or
an explicit `( ... )` — terminates only that subshell. The enclosing script
continues with whatever partial state it has and, having run to the end without
another failure, exits 0.

That outcome is worse than a crash: the job is green, the outputs are present
but empty or default, and nothing in the log distinguishes it from a clean pass.
A security gate that cannot fail loudly is not a gate.

Where a helper that can abort must feed a loop, its output SHALL be captured
into a variable first and the loop SHALL read from that variable, so the abort
propagates before the loop begins. The tool resolver is consumed this way.

#### Scenario: Requested scan tool does not exist
- **WHEN** `scan-tools` names a tool the platform does not offer
- **THEN** the run emits a `::error::` annotation naming the available tools and exits non-zero
- **AND** no scan is started

#### Scenario: Tool resolution feeds a loop
- **WHEN** the resolved tool list is iterated
- **THEN** the list has already been captured into a variable, so a failure during resolution has already aborted the run
- **AND** the run can never proceed to the scan step with an empty tool list

#### Scenario: A failing scan
- **WHEN** any scan reaches a terminal failed or cancelled state, or the wait exceeds `wait-timeout`
- **THEN** the run exits non-zero rather than reporting a pass with missing results

### Requirement: Credentials never reach a persisted surface
Credentials SHALL remain in process memory for the lifetime of the run: neither
the service-account password supplied as `token` nor the JWT obtained by
exchanging it SHALL be written to `GITHUB_OUTPUT`, to `GITHUB_STEP_SUMMARY`, or
to any log line. The JWT is attached to GraphQL requests as an `Authorization` header only.
The password is sent to the token endpoint as form data only.

The action's three outputs are the scan result ids, the highest severity and the
pass flag; nothing else is appended to the output file. The job summary is built
from the repository metadata, the gate configuration and the findings, and
contains no credential.

Failure diagnostics SHALL observe the same rule. When authentication fails, the
error description returned by the token endpoint is printed and the run aborts
with a message naming which inputs to check, without echoing the credential that
was rejected.

#### Scenario: Successful run
- **WHEN** a run completes and writes its outputs and job summary
- **THEN** neither file contains the JWT nor the `token` input value

#### Scenario: Authentication fails
- **WHEN** the token endpoint rejects the service account
- **THEN** the endpoint's error description is logged and the run fails with an error naming `service-account`, `token` and `tenant`
- **AND** the rejected credential does not appear in the log

#### Scenario: Token expiry during a long run
- **WHEN** the JWT is refreshed partway through a run because it is within two minutes of expiry
- **THEN** only its remaining lifetime in seconds is reported, never the token itself
