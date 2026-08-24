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

## Working agreement

These four apply to every change, without exception.

1. **Spec first, then tests, then code. In that order.**
   - **Spec.** Behaviour changes go through OpenSpec: propose the change and get the spec deltas
     right before writing anything. Never hand-edit `openspec/specs/`; that is what archiving is
     for. The workflow is in @CONTRIBUTING.md.
   - **Tests.** Write the tests against the agreed spec next, and watch them fail for the right
     reason. Each test carries a `# spec:` comment naming the requirement and scenario it proves.
   - **Code.** Only then implement, until the tests pass.

   Writing the code first and backfilling a spec to match defeats the point: the spec stops being
   a contract and becomes a description of whatever was built.
2. **Conventional Commits are mandatory, and they drive the version.** The type prefix decides the
   semver bump, so a mistyped commit produces a wrong release. Types, breaking-change marking and
   the MAJOR/MINOR/PATCH rules are in @CONTRIBUTING.md.
3. **Run the tests and the linter locally before you push.** Commands are in @docs/testing.md. CI
   runs on a shared self-hosted runner set, so a push that only exists to see whether it compiles
   takes capacity from everyone else. Fix it locally first.
4. **Watch CI after you push. Do not push and walk away.** `gh run watch`, or
   `gh pr checks <n> --watch`. If it fails, fix it or say so. A red check left behind is worse
   than no check, because the next person cannot tell your failure from theirs.

## Specs

Behaviour changes go through OpenSpec: @CONTRIBUTING.md
