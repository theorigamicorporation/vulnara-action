## Why

`DockerScanTool.name` is gone from the gateway (`vulnara-gateway-api` `c3648c96`, owner decision 3),
not deprecated. The adaptive selection added in this PR was written for the moment it disappeared,
and it works: verified against that commit's composed SDL, `{dockerScanTools(list:{}){items{id name
categories}}}` fails with `Cannot query field "name" on type "DockerScanTool".`, the narrowing
matches that message, and the retried `{dockerScanTools(list:{}){items{id categories}}}` is valid.

Working is not the same as worth keeping. Tolerating both shapes of `name` now means every run pays
a rejected request before its real one, forever, because attempt one can never succeed again. And
the only thing `name` was ever used for was matching a name-valued `scan-tools`, which owner
decision 3 retires: a name cannot be resolved, so the action should say so rather than ask for a
field it must not print.

`categories` is the opposite case. `gateway-url` is an action input, so a non-prod or self-hosted
gateway predating `DockerScanTool.categories` is a real deployment, and selecting that field
unconditionally there turns "labelled Uncategorised" into "the run fails and starts no scan" for a
tool id pinned in a workflow file we do not control.

Separately, `scan-tools: AEGIS` used to succeed silently. With `name` gone it cannot resolve, and
before this change the run reported `is not available to tenant`, sending the customer to look in the
Vulnara UI for a scanner that is there.

## What Changes

- `name` is removed from the catalogue selection entirely, and from the narrowable set. The happy
  path is one request again.
- `categories` stays narrowable, for a gateway that predates it.
- `scan-tools` resolves ids only. A non-id entry is rejected before the catalogue is consulted, with
  a message that names the entry, says the gateway does not resolve scanners by name, says a category
  label belongs to a category scan, and points at the application for the id. It no longer claims the
  tool is unavailable to the tenant.
- **BREAKING** for a workflow whose `scan-tools` holds a stored name. It stopped working when the
  gateway removed the field; this changes the error from misleading to accurate.
- `action.yml`'s `scan-tools` description says ids, because names are not accepted.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `scan-orchestration`: tools resolve by id only; the selection set carries no scanner name at all;
  the failure for a non-id entry states the real cause. `action-configuration` is unchanged: it
  enumerates the inputs and their required flags, not the shape of a value.

## Impact

- `entrypoint.sh`, `action.yml`, `README.md`, `docs/configuration.md`, `docs/development.md`,
  `docs/reference.md`, `test/orchestration_test.sh`, `test/reporting_test.sh`,
  `test/lib/harness.sh`, `test/fixtures/base/dockerScanTools.json`.
- `vulnara-site`: `src/docs/data/action.json` is generated from `action.yml` by the weekly
  `docs-sync` workflow, so #477's committed snapshot of the `scan-tools` description goes stale and
  has to be regenerated.
