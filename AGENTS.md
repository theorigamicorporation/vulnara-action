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

- There is no build step. Local checks are `shellcheck -S warning entrypoint.sh` and
  `docker build -t vulnara-action:dev .`. Both must be clean before review.
- An offline bash test suite under `test/` lands with the open `test/openspec-coverage` branch.
  It stubs `curl` and `sleep` on `PATH` so nothing reaches the network, and injects inputs with
  `env(1)` because GitHub passes them as dashed `INPUT_SERVICE-ACCOUNT` names that Bash cannot
  export. Work on that branch, and read its `test/README.md`, rather than starting a second suite.
- The action ships by tag. A merge to `main` changes nothing for consumers until the `v1` major
  tag moves.

## Conventions

- Read inputs through the `input()` helper, never `${INPUT_...}` directly. Reason:
  @docs/development.md
- Build every GraphQL body with `jq -n`. Never interpolate an input into a query string.
- Every endpoint keeps a production default in both `action.yml` and `entrypoint.sh` plus an input
  that overrides it.
- `resolve_tools` is consumed through a process substitution (`entrypoint.sh:248`), so a `fail()`
  inside it kills only the subshell and the action still exits 0. Do not add a new gate check
  inside a process substitution. See @docs/troubleshooting.md
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
3. **Run tests and lint locally before pushing.** CI is a shared self-hosted runner set.
4. **Watch CI after pushing** (`gh run watch`, `gh pr checks <n> --watch`) and fix or report what
   fails.
