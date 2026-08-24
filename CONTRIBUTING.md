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

Conventional commit subjects, lower case, scope optional:

```
feat: add fail-on threshold for dependency findings
fix: do not double repo name in URL when falling back to cloneUrl
docs: document the scanner codename mapping
```

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
