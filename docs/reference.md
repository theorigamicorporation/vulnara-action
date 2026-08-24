# Reference

[Back to the README](../README.md)

What the action decides and what it prints: the severity gate, the scanner codenames, and the
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
- A tool-resolution failure does **not** fail the job. See
  [Troubleshooting](troubleshooting.md#a-tool-resolution-failure-passes-the-gate).

## Scanners

`scan-tools` accepts either the tool id or the tool name from Vulnara's `dockerScanTools`.
Name matching is case-insensitive; id matching is exact. Comma-separate for several, and
surrounding whitespace is trimmed.

In the log and the job summary the action prints the platform codename rather than the
internal tool name, mirroring the titles the web app uses:

| Tool name | Displayed as |
|---|---|
| `AEGIS`, `aegis` | Ripley |
| `pdd` | Bishop |
| `trivy` | Hicks |
| `secret_scanner` | Ash |
| `SECRET_SCANNER`, `Secret Scanner` | Secret Scanner |
| `personal_data_scanner`, `PERSONAL_DATA_SCANNER`, `Personal Data Scanner` | Personal Data Scanner |
| anything else | the name unchanged |

Note that the lower-case `secret_scanner` maps to `Ash`, while the upper-case and spaced
spellings pass through as `Secret Scanner`. The codename is display only: `scan-tools` still
takes the tool name or id, never the codename.

An unknown name lists what is available:

```
scan tool 'nosuchtool' not found. Available: AEGIS, pdd, trivy, secret_scanner
```

## The job summary

When `GITHUB_STEP_SUMMARY` is set, the action appends, in order:

1. A verdict heading, passed or failed, and a table of repository (linked when the platform
   returned a URL), provider and visibility, branch, languages, the gate setting, the highest
   severity and the run duration.
2. The per-severity counts and the total.
3. One row per scan: codename, duration, finding count, and a link to the scan at
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
| anything else | `<repo>/blob/<sha>/<file>#L<line>` |

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
