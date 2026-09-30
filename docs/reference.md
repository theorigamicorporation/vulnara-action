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

- The gate reads `scanFindings` only, which are code and secret findings. Dependency and
  network findings are not consulted, so they cannot fail the build today.
- A scan ending `FAILED` or `CANCELLED` fails the job on its own, before any findings are read.
- A tool-resolution failure aborts the run before any scan is started, so a name typo fails the
  job rather than passing it with nothing scanned.

## Scanners

`scan-tools` accepts a tool id from Vulnara's `dockerScanTools`. Comma-separate for several, and
surrounding whitespace is trimmed. Ids are listed against each scanner in the Vulnara
application. **Pass ids.** A tool name is still matched, case-insensitively, while the gateway
still returns one, but scanner names are being removed from every customer-facing part of the
API, and a `scan-tools` entry that names one stops resolving on the day that lands.

The action tolerates that removal rather than breaking on it. The `dockerScanTools` selection set
is assembled from the fields the schema actually has: a field the gateway has dropped is
identified from the validation error and dropped from the query, then the query is retried.
Selecting it unconditionally would fail the whole query, so a run that passed an id would break
exactly as hard as one that passed a name, and the annotation would blame the workflow's input
for a change made on the platform side. Any GraphQL error that is not a rejected optional field
still aborts the run with the gateway's own wording.

Nothing the action prints identifies a scanner. A scan is labelled by the **category** it covers,
which is what the scan looked for rather than what ran it:

| Wire value | Label |
|---|---|
| `sast` | Code analysis |
| `sca` | Dependencies |
| `secrets` | Secrets |
| `pii` | Personal data |

A scanner serves one or more categories, so a label can be a set, joined with commas and
deduplicated: two categories that render to the same label collapse to one, because a repeated
label counts scanners. When no category can be resolved — a gateway that does not expose
`categories`, or a tool with none recorded — the label is `Uncategorised`. That is display only:
it is never sent to the platform and is not a category the platform knows about.

An entry matching no id, and no name while names still resolve, aborts the run before any scan
starts. The failure names what you passed and where to look the right value up, and deliberately
does not list the scanners that would have worked — a CI log is world-readable on a public
repository, and a typo should not hand a reader the roster:

```
scan tool 'nosuchtool' is not available to tenant 'acme'. Open https://vulnara.rso.dev to see the scanners this workspace can run, and pass the id shown there.
```

An entry that is not an id says so instead of blaming the tenant's scanner availability.
`scan-tools` takes ids: the gateway does not resolve scanners by name any more, and a category
label belongs to a category scan rather than to this input:

```
scan tool 'AEGIS' is not a scan tool id. scan-tools takes ids: this Vulnara gateway does not resolve scanners by name, and a category label belongs to a category scan rather than to scan-tools. Open https://vulnara.rso.dev, copy the id shown against the scanner you want, and use that.
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

## Related

- [Configuration](configuration.md) for the inputs that drive the gate,
  [Architecture](architecture.md) for how the findings are collected,
  [Troubleshooting](troubleshooting.md) for when the gate does not behave.
- [`openspec/specs/findings-gate-reporting/spec.md`](../openspec/specs/findings-gate-reporting/spec.md)
  is the normative version of this page.
