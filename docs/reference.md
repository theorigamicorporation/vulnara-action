# Reference

[Back to the README](../README.md)

What the action decides and what it prints: the severity gate, how scanners are named, and the
job summary it appends.

## The severity gate

Severities are ranked, `fail-on` is mapped to a threshold rank, and the job fails when the
highest observed rank is **greater than or equal to** the threshold. The comparison is
case-insensitive. Any severity the action does not recognise ranks `0`, so it never trips the
gate and is not counted in the four severity totals.

| Severity | Rank |
|---|---|
| `CRITICAL` | 4 |
| `HIGH` | 3 |
| `MEDIUM` | 2 |
| `LOW` | 1 |
| anything else | 0 |

| `fail-on` | Threshold rank | Fails the job on |
|---|---|---|
| `critical` (default) | 4 | Critical |
| `high` | 3 | High, Critical |
| `medium` | 2 | Medium and above |
| `low` | 1 | Any ranked finding |
| `none` | 99 | Never |

Any other value aborts the run before the first network call with
`invalid fail-on '<value>' (expected none|low|medium|high|critical)`.

On failure the action emits, as a GitHub error annotation:

```
scan gate failed: highest severity 'Critical' meets/exceeds fail-on 'high'
```

Three limits worth knowing:

- The gate reads `scanFindings`, which are code and secret findings, and, when a web
  application scan ran, its findings. Dependency and network findings are not consulted, so
  they cannot fail the build today.
- Triage decisions are not consulted for either kind: a finding marked not affected in Vulnara
  still counts towards the gate.
- A scan ending `FAILED` or `CANCELLED` fails the job on its own, before any findings are read.
- A tool-resolution failure aborts the run before any scan is started, so an id typo fails the
  job rather than passing it with nothing scanned.

## Scanners

`scan-tools` takes scanner ids only, from Vulnara's `dockerScanTools`. Comma-separate for
several, and surrounding whitespace is trimmed. A scanner name is not accepted: the gateway no
longer returns names, so there is nothing to match one against, and an entry that is not an id
fails the run before any request is made.

To find the ids your workspace can run, use the Vulnara CLI, which lists each scanner's id and
categories and never its name:

```sh
vulnara docker_scan_tools
```

or run the same GraphQL query against the gateway yourself:

```graphql
{ dockerScanTools { items { id categories } } }
```

The action selects only `id` and `categories` from `dockerScanTools`. `categories` is optional: a
gateway that predates the field rejects it with a validation error, the field is dropped and the
query retried, and every scan is then labelled `Uncategorised`. Any GraphQL error that is not that
rejected field still aborts the run with the gateway's own wording.

Nothing the action prints identifies a scanner. A scan is labelled by the **category** it covers,
which is what the scan looked for rather than what ran it:

| Wire value | Label |
|---|---|
| `sast` | Code analysis |
| `sca` | Dependencies |
| `secrets` | Secrets |
| `pii` | Personal data |
| `dast` | Web application |

`Web application` is also the label of the scan `web-target-id`/`web-url` starts; see
[Web application scans](#web-application-scans).

A scanner serves one or more categories, so a label can be a set, joined with commas and
deduplicated: two categories that render to the same label collapse to one, because a repeated
label counts scanners. When no category can be resolved — a gateway that does not expose
`categories`, or a tool with none recorded — the label is `Uncategorised`. That is display only:
it is never sent to the platform and is not a category the platform knows about.

An entry matching no id aborts the run before any scan starts. The failure names what you passed
and where to look the right value up, and deliberately does not list the scanners that would have
worked — a CI log is world-readable on a public repository, and a typo should not hand a reader the
roster:

```
scan tool '00000000-0000-0000-0000-000000000000' is not available to tenant 'acme'. List the ids this workspace can run with 'vulnara docker_scan_tools' (vulnara-cli) or the GraphQL query 'dockerScanTools { id categories }', and pass one of those.
```

An entry that is not an id says so instead of blaming the tenant's scanner availability.
`scan-tools` takes ids: the gateway does not resolve scanners by name any more, and a category
label belongs to a category scan rather than to this input:

```
scan tool 'my-scanner' is not a scan tool id. scan-tools takes ids: this Vulnara gateway does not resolve scanners by name, and a category label belongs to a category scan rather than to scan-tools. List the ids this workspace can run with 'vulnara docker_scan_tools' (vulnara-cli) or the GraphQL query 'dockerScanTools { id categories }', and pass one of those.
```

## Resolving the repository

`repository` defaults to `GITHUB_REPOSITORY`. The action first looks the repository up by the
last segment of `repository` and takes the candidate whose git entity name equals the first
segment, case-insensitively. That is the whole rule for GitHub, GitLab, Bitbucket and Forgejo,
apart from the [first-result fallback](troubleshooting.md#the-wrong-repository-is-scanned).

Vulnara stores an Azure DevOps repository as `<project>/<repo>` under a git entity named after
the Azure organization, so when the first lookup finds no owner match the action searches for
the last segment and considers `azure_devops` repositories only. `repository` then accepts:

| Form | Matches |
|---|---|
| `<org>/<project>/<repo>` | `<project>/<repo>` under the entity `<org>` |
| `<project>/<repo>` | `<project>/<repo>` under any Azure DevOps entity |
| `<org>/<repo>` | the one repository named `<repo>` in any project of `<org>` |

More than one candidate fails the run before any scan starts, and lists the candidates:

```
repository 'acme/widgets' is ambiguous in Vulnara (tenant 'my-tenant'): acme/web/widgets, acme/api/widgets. Pass the full org/project/repo.
```

## The job summary

When `GITHUB_STEP_SUMMARY` is set, the action appends, in order:

1. A verdict heading, passed or failed, and a table of repository (linked when the platform
   returned a URL), provider and visibility, branch, languages, the gate setting, the highest
   severity and the run duration.
2. The per-severity counts and the total.
3. One row per scan: the category it covered, duration, finding count, and a link to the scan at
   `<app-url>/repository-scans/<id>`.
4. A detailed findings table, only when the total is above zero.

The detailed table lists findings that have a `file`, sorted by severity descending, capped at
the top 50. When more were located, a line states how many. Findings with no file are omitted
from that table, though they still count towards the totals and the gate.

Each row links to the exact line at the scanned commit, built from the repository URL, the
finding's `commitScan.commitHash`, its file and its line:

| Provider | Link form |
|---|---|
| `gitlab` | `<repo>/-/blob/<sha>/<file>#L<line>` |
| `bitbucket` | `<repo>/src/<sha>/<file>#lines-<line>` |
| `azure_devops` | `<repo>?path=/<file>&version=GC<sha>&line=<line>&lineEnd=<line>&lineStartColumn=1&lineEndColumn=1` |
| `forgejo` | `<repo>/src/commit/<sha>/<file>#L<line>` |
| `github` and anything else | `<repo>/blob/<sha>/<file>#L<line>` |

For `azure_devops` the repository URL is `<htmlUrl>/<project>/_git/<repo>`, taken from a
`repositoryName` of the form `<project>/<repo>`. Credentials in a `cloneUrl` fallback are
dropped.

When the repository URL or the commit hash is missing, the location is rendered as plain text
rather than a link.

The console log carries the same numbers, plus a `view scan` line per scan, and is written to
stderr with a `vulnara:` prefix throughout.

## Web application scans

Set `web-target-id` or `web-url` to run one web application scan in the same job, alongside the
repository scans or, with `scan-tools` empty, on its own.

**Which target.** `web-target-id` scans that web target. `web-url` looks for a web target with
the same base URL, comparing scheme and host case-insensitively, ignoring a trailing dot on the
host and a fragment, and reading an empty path as `/` (`https://App.example.com` matches
`https://app.example.com/`, `https://app.example.com/shop` does not). One match is reused. None
registers the URL as a new web target, named after the URL. More than one fails the run and asks
for `web-target-id`. Scope and excluded paths are set on the target in Vulnara.

**Consent.** Registering a web target records an attestation that you own the application or are
authorised to scan it. The action never makes that attestation for you: `web-url` is refused,
before any request, unless `web-ownership-consent` is exactly `true`. Because the workflow cannot
know whether the URL will be reused or registered, the rule is the same for both. `web-target-id`
does not need it, since the target's attestation was recorded when it was registered.

**Fail closed.** Before resolving or registering anything, the action checks that the workspace
may run web application scans and stops if it may not. Every refusal fails the run with a
message saying what it means, followed by the gateway's own error lines:

| Refusal | Message starts with |
|---|---|
| Web application scanning not enabled | `web application scanning is not enabled for workspace '<tenant>'` |
| A plan limit (`...LIMIT_EXCEEDED`) | `...: the workspace's plan limit for web application scanning is reached (<code>)` |
| Target not publicly reachable | `...: the web target does not resolve to public addresses only` |
| Target not found | `...: web target not found in workspace '<tenant>'` |
| URL rejected on registration | `registering web-url '<url>': the gateway rejected the request: <field>: <reason>` |

A URL carrying credentials is refused before any request and is not echoed.

**Waiting.** The web scan is started after the repository scans, so they run side by side, and is
waited on after them in its own `wait-timeout` window, polling every `poll-interval`. `FAILED`,
`CANCELLED` or the deadline fails the run, naming `Web application` and the scan result id.

**Gate and outputs.** The web scan's findings are counted per severity and added to the run's
totals, so the one `fail-on` gate, `highest-severity` and `passed` cover both kinds of scan.
`web-target-id` and `web-scan-result-id` are written as outputs; `scan-result-ids` stays the
repository scans.

**Summary.** The job summary gains a `Web target` row, a `Web application` row in the scans
table linking to `<app-url>/web-targets/<id>`, and a `Web application` section: the target, its
URL, the scan duration, the findings by severity and, when there are any, the top 50 by severity
with the finding name, the URL it matched at and its CVE and CWE ids. A web-only run leaves the
repository rows out. Nothing in the log or the summary names the scanner that ran.

## Related

- [Configuration](configuration.md) for the inputs that drive the gate,
  [Architecture](architecture.md) for how the findings are collected,
  [Troubleshooting](troubleshooting.md) for when the gate does not behave.
- [`openspec/specs/findings-gate-reporting/spec.md`](../openspec/specs/findings-gate-reporting/spec.md)
  is the normative version of this page.
