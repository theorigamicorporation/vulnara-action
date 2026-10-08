## ADDED Requirements

### Requirement: Run a web application scan
When `web-target-id` or `web-url` is set, the system SHALL run one web application scan in
addition to any repository scans, and SHALL fail closed at every step:

1. It SHALL read `scanCategories` and fail, before resolving or registering a target, when the
   list does not include `DAST`, with a message that web application scanning is not enabled
   for the workspace.
2. For `web-target-id` it SHALL read `webTarget(id)` and fail with a not-found message when the
   gateway does not return it.
3. For `web-url` it SHALL list `webTargets` filtered on the URL's host and compare base URLs on
   a normalised key (scheme and host lowercased, trailing host dot dropped, empty path read as
   `/`, fragment dropped). One match SHALL be reused. More than one SHALL fail the run and ask
   for `web-target-id`. None SHALL register the URL with `createWebTarget` and
   `ownershipConsent: true`.
4. It SHALL start the scan with `startWebScan(input: {webTargetId})` and read the scan result
   id from `webScanResult.id`. A refusal SHALL fail the run: `NO_SCANNER_FOR_CATEGORY` with the
   not-enabled message, a code ending `LIMIT_EXCEEDED` with a plan-limit message,
   `WEB_TARGET_ADDRESS_REFUSED` with a message that only publicly reachable targets can be
   scanned, `NOT_FOUND` with the not-found message; the gateway's own error lines SHALL be
   printed too.
5. It SHALL poll `webScanResult(id) { status }` every `poll-interval` seconds within its own
   `wait-timeout` window, as for each repository scan, failing on `FAILED`, `CANCELLED` or the
   deadline.

The scan SHALL be labelled `Web application` and nothing printed SHALL name the scanner.

#### Scenario: Web-only run
- **WHEN** only `web-target-id` is set and the workspace lists `DAST`
- **THEN** no repository or scan tool is resolved and no repository scan is started
- **AND** `startWebScan` is sent with that `webTargetId`

#### Scenario: Web scanning not enabled
- **WHEN** `scanCategories` does not include `DAST`
- **THEN** the run fails saying web application scanning is not enabled for the workspace
- **AND** neither `createWebTarget` nor `startWebScan` is sent

#### Scenario: Start refused for want of a scanner
- **WHEN** `startWebScan` answers `NO_SCANNER_FOR_CATEGORY`
- **THEN** the run fails with the not-enabled message

#### Scenario: Registered URL reused
- **WHEN** `web-url` is `https://App.example.com` and a target with base URL
  `https://app.example.com/` exists
- **THEN** that target is scanned and `createWebTarget` is not sent

#### Scenario: Unregistered URL registered
- **WHEN** `web-url` matches no target and consent is given
- **THEN** `createWebTarget` is sent with that `baseUrl` and `ownershipConsent: true`, and the
  new target is scanned

#### Scenario: Ambiguous URL
- **WHEN** two targets match `web-url`
- **THEN** the run fails asking for `web-target-id` and nothing is registered or started

#### Scenario: Web scan fails or times out
- **WHEN** the web scan ends `FAILED`, or is still running after `wait-timeout` seconds
- **THEN** the run fails naming `Web application` and the scan result id
