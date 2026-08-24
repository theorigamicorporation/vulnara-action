# Security policy

Vulnara is a security product, and this action runs inside other people's CI with
credentials that can reach a Vulnara tenant. Vulnerability reports are welcome and
are handled privately.

## Reporting a vulnerability

Do not open a public issue, discussion or pull request for a suspected vulnerability.

Report it privately through GitHub:
[Security -> Report a vulnerability](https://github.com/theorigamicorporation/vulnara-action/security/advisories/new)
on this repository. GitHub private vulnerability reporting keeps the report visible
only to the maintainers until an advisory is published.

If you would rather not use GitHub, email **security@vulnara.io** instead.

Please include:

- the affected version or tag (`v1`, `v1.0.5`, or a commit sha)
- what an attacker gains, and what access they need to get it
- a minimal workflow or command that reproduces the issue
- any logs, with tokens redacted

We aim to acknowledge a report within three working days and to agree a disclosure
timeline with the reporter. Please give us a chance to ship a fix before disclosing
publicly.

## Scope

In scope:

- `entrypoint.sh`, `action.yml`, the `Dockerfile` and anything else published from
  this repository
- leakage of the service-account token, the exchanged JWT, or the git token id into
  logs, the job summary, action outputs or the workflow environment
- gate bypasses, meaning any input or platform response that makes the action exit `0`
  when the configured `fail-on` threshold should have failed the job

Out of scope here (report these to the Vulnara platform team, not through this repo):

- vulnerabilities in the Vulnara gateway, API, scanners or web app
- findings produced by a scanner about your own code

## Handling secrets

- Pass `token` from a GitHub Actions secret, never from a literal or a `vars` entry.
- The action prints no credentials: the JWT stays in memory and is never written to
  `GITHUB_OUTPUT` or `GITHUB_STEP_SUMMARY`. If you find a path where a secret reaches
  the log, that is a vulnerability and we want to hear about it.
- Use a service account scoped to the tenant you scan, and rotate its token if it has
  ever appeared in a build log.
