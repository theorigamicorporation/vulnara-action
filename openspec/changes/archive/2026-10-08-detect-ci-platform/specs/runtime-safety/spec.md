## MODIFIED Requirements

### Requirement: Credentials never reach a persisted surface
Credentials SHALL remain in process memory for the lifetime of the run: neither
the service-account password supplied as `token` nor the JWT obtained by
exchanging it SHALL be written to any output sink, any summary sink, any file
under `report-dir`, any platform logging command, or any log line. The output
and summary sinks are those the `ci-platform` capability names for each platform,
`GITHUB_OUTPUT` and `GITHUB_STEP_SUMMARY` among them. The JWT is attached to
GraphQL requests as an `Authorization` header only. The password is sent to the
token endpoint as form data only.

The action's outputs are the scan result ids, the highest severity, the pass flag
and, when a web scan ran, the web target and web scan result ids; nothing else is
written to an output sink. The summary is built from the repository metadata, the
gate configuration and the findings, and contains no credential.

Failure diagnostics SHALL observe the same rule. When authentication fails, the
error description returned by the token endpoint is printed and the run aborts
with a message naming which inputs to check, without echoing the credential that
was rejected.

#### Scenario: Successful run
- **WHEN** a run completes and writes its outputs and job summary
- **THEN** neither file contains the JWT nor the `token` input value

#### Scenario: Successful run on a file-sink platform
- **WHEN** the platform is `gitlab` and a run completes
- **THEN** neither `outputs.env` nor `summary.md` under `report-dir` contains the JWT nor the
  `token` input value

#### Scenario: Authentication fails
- **WHEN** the token endpoint rejects the service account
- **THEN** the endpoint's error description is logged and the run fails with an error naming `service-account`, `token` and `tenant`
- **AND** the rejected credential does not appear in the log

#### Scenario: Token expiry during a long run
- **WHEN** the JWT is refreshed partway through a run because it is within two minutes of expiry
- **THEN** only its remaining lifetime in seconds is reported, never the token itself
