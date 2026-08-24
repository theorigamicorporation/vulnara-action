# Contributing

`vulnara-action` is a Docker container action implemented as a single Bash script.
There is no build step and no package manager: everything runs from `entrypoint.sh`
on `alpine:3.20` with `bash`, `curl` and `jq`.

## Requirements

- `bash` 4+ and `jq` for local work
- `docker` if you want to build the action image
- `shellcheck` for linting

## Branches

Branch off `main`, one topic per branch:

| Prefix | Use |
|---|---|
| `feat/` | new inputs, outputs or behaviour |
| `fix/` | bug fixes |
| `docs/` | documentation only |
| `test/` | test-only changes |
| `chore/` | tooling, CI, dependencies |

## Commits

**Conventional Commits are mandatory.** They are not a style preference: release tooling parses the
type prefix to build release notes and to decide the next semantic version, so a wrongly typed
commit produces a wrong release.

```
<type>(<optional scope>): <description>

[optional body]

[optional footer]
```

Allowed types:

| Type | Use for | Version effect |
|---|---|---|
| `feat` | New behaviour | MINOR |
| `fix` | Bug fix | PATCH |
| `perf` | Performance, no behaviour change | PATCH |
| `refactor` | Internal change, no behaviour change | none |
| `docs` | Documentation only | none |
| `test` | Tests only | none |
| `build` | Build system or dependencies | none |
| `ci` | CI configuration | none |
| `chore` | Tooling, housekeeping | none |
| `revert` | Reverts a previous commit | matches what it reverts |

### Breaking changes

A breaking change is a MAJOR bump and must be marked, either with a `!` after the type or with a
`BREAKING CHANGE:` footer. Both forms are valid; the footer is preferred when the reason needs
explaining.

```
feat(api)!: require X-TENANT-ID on the corroboration endpoint

BREAKING CHANGE: callers that relied on the unscoped lookup must now send the tenant header.
```

### Versioning

Releases follow [Semantic Versioning](https://semver.org/): `MAJOR.MINOR.PATCH`, bumped from the
commit types above. MAJOR for incompatible changes, MINOR for backwards-compatible additions,
PATCH for backwards-compatible fixes.

Rules that catch people out:

- One logical change per commit. A commit that both fixes a bug and adds a feature cannot be typed
  correctly, so split it.
- The subject is imperative and lower case, under about 72 characters, with no trailing full stop.
- The scope is optional but should name a real module or capability when used, not a file name.
- `revert` commits should name the reverted SHA in the body.

## The OpenSpec workflow

Behaviour is specified before it is implemented. The specs live in `openspec/specs/`
and are the source of truth for what the action does.

1. `/opsx:propose` writes a change under `openspec/changes/<id>/` with a proposal,
   spec deltas and a task list.
2. `/opsx:apply` works through the tasks and implements them.
3. `/opsx:archive` folds the deltas into `openspec/specs/` and moves the change to
   `openspec/changes/archive/`.

If you change what the action does, update the affected capability in the same PR.
The badge counts in the README are regenerated from `openspec/` by
`scripts/openspec_badges.py`, which the `OpenSpec Badges` workflow runs on `main`.

Deeper guides live in [`docs/`](docs/): [architecture](docs/architecture.md),
[configuration](docs/configuration.md), [reference](docs/reference.md),
[troubleshooting](docs/troubleshooting.md), [development](docs/development.md) and
[testing](docs/testing.md). A behaviour change usually touches one of them.

### Writing a requirement

`openspec validate --specs --strict` gates merges, so a malformed requirement blocks the branch.
Two rules the validator applies that are easy to trip:

- **SHALL or MUST must appear on the requirement's first line.** The validator takes only that
  line as the requirement text, so a keyword on line two fails even though the paragraph reads
  correctly. Lead with the obligation:

  ```
  ### Requirement: Never show a scanner's internal name
  Scanners SHALL be shown under their product names, never under the name of the
  image that runs them.
  ```

  not:

  ```
  ### Requirement: Never show a scanner's internal name
  Scanners are stored under the name of the image that runs them, and SHALL be
  shown under their product names.
  ```

- **Every requirement needs at least one `#### Scenario:`**, in WHEN/THEN form.

Run `openspec validate --specs --strict` locally before pushing. `just specs` does it where a
justfile exists.

## Checks before opening a PR

```bash
shellcheck -S warning entrypoint.sh
docker build -t vulnara-action:dev .
python3 scripts/openspec_badges.py .
```

## Anything user-visible

`action.yml`, `README.md` and `openspec/specs/action-configuration/spec.md` all
enumerate the inputs and outputs. A new input has to appear in all three.

This repository is public. Keep examples, fixtures and documentation free of real
tenant ids, hostnames, credentials and any other internal detail: use `example.test`
hostnames and obviously fake identifiers.
