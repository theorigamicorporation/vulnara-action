# AGENTS.md

A container GitHub Action that runs a Vulnara scan on a repository and gates the job on the
findings. `entrypoint.sh` is the whole implementation, `action.yml` is the interface.

## This repository is public

Everything committed here is world-readable, including anything you add. Keep examples, fixtures,
tests and docs free of real hostnames, tenant ids, client ids and credentials. Use `example.test`
hostnames and obviously fake ids, as the existing fixtures do.

## Read first

@README.md
@docs/architecture.md
@docs/development.md

Inputs, outputs and env: @docs/configuration.md | GraphQL operations: @docs/reference.md |
Verification: @docs/testing.md | Known issues: @docs/troubleshooting.md

## Working here

- There is no build step. The local gate is `just ci`: `shellcheck -S warning` over the action
  and the test sources, the offline test suite, and `docker build -t vulnara-action:dev .`. All
  three must be clean before review.
- The offline bash test suite lives under `test/` on `main`. It stubs `curl` and `sleep` on
  `PATH` so nothing reaches the network, and injects inputs with `env(1)` because GitHub passes
  them as dashed `INPUT_SERVICE-ACCOUNT` names that Bash cannot export. Extend it, and read
  `test/README.md` first, rather than starting a second suite.
- The action ships by tag. A merge to `main` changes nothing for consumers until the `v1` major
  tag moves.

## Conventions

- Read inputs through the `input()` helper, never `${INPUT_...}` directly. Reason:
  @docs/development.md
- Build every GraphQL body with `jq -n`. Never interpolate an input into a query string.
- Every endpoint keeps a production default in both `action.yml` and `entrypoint.sh` plus an input
  that overrides it.
- Never put a gate check inside a process substitution or any other subshell: a `fail()` there
  kills only the subshell and the action still exits 0. `resolve_tools` is captured into a
  variable for exactly that reason. See @docs/troubleshooting.md
- A new input lands in `action.yml`, `docs/configuration.md` and
  `openspec/specs/action-configuration/spec.md` in the same pull request.

## Do not

- Do not write a credential to `GITHUB_OUTPUT`, `GITHUB_STEP_SUMMARY` or the log. The JWT stays
  in memory.
- Do not hand-edit `openspec/specs/` outside an archive step, or `docs/badges/*.svg`, which are
  generated.

## Comments

Comment sparingly, and only where the code cannot speak for itself. A comment restating what the
line does is noise that goes stale.

Write one when:

- **A decision was made and the alternative looks more obvious.** Say why, so nobody "fixes" it
  back. If the reasoning came from an incident, name it.
- **You observed something and left it.** A known defect, a workaround, a constraint imposed by a
  dependency. Say what is wrong and why it was not fixed here.
- **The behaviour would surprise a careful reader.** Ordering that is load-bearing, a value that
  looks arbitrary but is not, a subtlety in a library.

Do not write one for what the code already says, to narrate a diff, or to mark authorship. Prefer a
clearer name or a smaller function first.

Keep it to a line or two. If it needs a paragraph, it belongs in `docs/`, and the comment should
point there.

## Working agreement

1. **Spec, then tests, then code.** Propose the OpenSpec change and settle the deltas before
   writing anything; then tests, each with a `# spec:` comment naming its requirement and
   scenario; then implement. Never hand-edit `openspec/specs/`. Workflow: @CONTRIBUTING.md
2. **Conventional Commits are mandatory.** The type prefix drives the semver bump. Types and
   breaking-change marking: @CONTRIBUTING.md
3. **Run `just ci` before pushing.** It is the same set of gates CI runs, so a failure here is a
   failure there, found in seconds instead of minutes. CI is a shared self-hosted runner set and
   the queue has reached 200+ jobs; a push that could have been checked locally costs everyone.
4. **Use the toolchain the repo pins, never the system one.** `asdf` manages Go, Node, `just`,
   `actionlint` and `ruff` here; honour `.tool-versions` where it exists. Python comes from the
   repo's `.venv`, built on the interpreter in `.python-version` — `just setup` provisions it, via
   `uv` when the system has no matching interpreter. A venv on the wrong minor does not fail
   politely: it fails as a `SyntaxError` during collection, pointing at a line that is correct.
5. **Wait for CI to finish before calling the work done**, and read the result from the run's
   jobs rather than the PR summary. Three sources disagree, in this order of reliability:

   | Source | Trust |
   |---|---|
   | `gh pr checks` / the PR page | Caches. Has reported green while checks were still running. |
   | `check-runs` on the head SHA | Better, but lags in *both* directions — including reporting `in_progress` for minutes after a job finished. |
   | `actions/runs/<id>/jobs` | Authoritative: per-step status and conclusion. |

   ```
   sha=$(gh pr view <n> --json headRefOid -q .headRefOid)
   gh api repos/<owner>/<repo>/commits/$sha/check-runs        # fast, may lag
   gh api repos/<owner>/<repo>/actions/runs/<id>/jobs         # authoritative
   ```

   A check that does not exist is not a check that passed — a path-filtered workflow can leave a
   PR with no signal at all. If nothing ran, say so rather than reporting green.
6. **Report what you actually observed.** If CI has not finished, say it has not finished. An
   honest "I have not seen this go green" is worth more than an optimistic summary, and every
   claim in a PR body is checkable by whoever reads it next.
