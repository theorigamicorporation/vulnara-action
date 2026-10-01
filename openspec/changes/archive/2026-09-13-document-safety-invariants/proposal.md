## Why

The fifteen existing requirements are traced by the offline suite, but four
things this action already does have no requirement at all — two of them safety
properties the repository treats as load-bearing.

**The fail-closed invariant has no spec.** `fail()` exits the process, so a gate
check inside a subshell kills only the subshell and the action exits 0 with an
empty result. This is the repository's own top stated hazard and the reason
`resolve_tools` is captured into a variable rather than consumed through a
process substitution. It lives in `AGENTS.md` as a convention. A convention is
not a requirement: nothing normative forbids the next contributor from writing
`while read ... done < <(resolve_tools)` and silently turning a failing gate
into a passing build.

**Credential non-leakage has no spec either.** The service-account password and
the JWT minted from it stay in shell variables and are written to nothing: not
`GITHUB_OUTPUT`, not the job summary, not the log. `AGENTS.md` says so; no
requirement does.

**Boolean input coercion is undocumented.** `create-issue` and `auto-remediate`
are compared against the literal string `true`, so `TRUE`, `yes`, `1` and `on`
all resolve to false and are sent to the gateway as `false`. A user who writes
`create-issue: True` gets no issue and no warning.

**The documented `auto-remediate` dependency is not enforced.** `action.yml`
describes `auto-remediate` as requiring `create-issue`, but nothing checks it:
`auto-remediate: true` with `create-issue` left at its default sends
`createIssue: false, autoRemediate: true` to the gateway.

Minor: `git-token-id` is the only optional input missing from the defaults
enumeration, and `tar` is installed in the image but absent from the four
packages the interface requirement lists.

## What changes

A new `runtime-safety` capability carries the two safety properties: gate checks
must run in the script's own process, and credentials must not reach any
persisted surface.

`action-configuration` gains a requirement for boolean coercion that states both
the literal-match rule and the fact that the `auto-remediate` dependency is
documented but unenforced. Two existing requirements are corrected: the
interface requirement to list `tar`, and the defaults requirement to include
`git-token-id`.

The unenforced dependency is recorded as it is. Enforcing it would change what a
workflow that sets `auto-remediate: true` alone does today, which is a behaviour
change and belongs in its own proposal.

## Impact

Specs only. No change to `entrypoint.sh`, `action.yml` or the
`Dockerfile`. Two in-flight changes touch `scan-orchestration`; this change does
not.
