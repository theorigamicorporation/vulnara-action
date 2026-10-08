## Why

Vulnara scans repositories on five providers (`github`, `gitlab`, `bitbucket`, `azure_devops`,
`forgejo`), but the action only runs inside GitHub Actions: it reads the branch and repository
from `GITHUB_*` variables, annotates with `::error::`, and writes its outputs and job summary to
`GITHUB_OUTPUT` and `GITHUB_STEP_SUMMARY`. Customers on the other providers cannot gate their
pipelines on Vulnara today.

Every one of those CI systems can run a container, so the plan is one image with a thin wrapper
per CI system, added one platform at a time. GitLab goes first: it has a self-service catalog
(the GitLab CI/CD Catalog) and we already have a GitLab workspace to publish the component from.
This change adds the platform layer to the image with GitHub and GitLab as its first two
platforms. Bitbucket, Forgejo and Azure DevOps each extend it in their own later change.

## What Changes

- The script detects the CI platform it runs on (`github`, `gitlab` or `none`) from the
  environment, with a new `ci-platform` input that overrides detection.
- `branch` and `repository` default from the detected platform's own variables. On GitLab that
  is the merge request source branch or the commit branch, and `CI_PROJECT_PATH`.
- Error and warning annotations, and collapsible log groups, are emitted in the detected
  platform's syntax: `ERROR:` / `WARNING:` lines and collapsible sections on GitLab.
- Outputs and the Markdown summary go to the platform's sink. On GitLab they are written to
  `outputs.env` (dotenv) and `summary.md` in a report directory, which the GitLab component
  publishes as artifacts, and the summary is also printed in a collapsed log section. A new
  `report-dir` input overrides that directory.
- A GitLab project under a subgroup (`group/sub/project`) resolves by its full namespace.
  Vulnara stores the subgroup path as the git entity name, and the resolver today matches only
  the first segment.
- When the same `owner/name` exists under several providers in one tenant, the resolver prefers
  the repository on the provider the pipeline is running on, so a GitLab pipeline does not scan
  and gate on the tenant's GitHub twin.

GitHub behaviour is unchanged: on GitHub the detected platform is `github` and every sink,
annotation and default is exactly what it is now, so this is a MINOR bump. The GitLab CI/CD
component and the public image it pulls are separate follow-up changes.

## Capabilities

### New Capabilities

- `ci-platform`: detecting the CI platform and mapping branch, repository, annotations, log
  groups, outputs and the summary onto it.

### Modified Capabilities

- `action-configuration`: `Default optional inputs` takes `branch` and `repository` from the
  detected platform, and the interface gains the `ci-platform` and `report-dir` inputs.
- `findings-gate-reporting`: `Publish action outputs` and `Render the job summary` write to the
  platform's sink instead of only `GITHUB_OUTPUT` and `GITHUB_STEP_SUMMARY`.
- `runtime-safety`: `Credentials never reach a persisted surface` covers every platform sink,
  including the files under `report-dir`.
- `scan-orchestration`: new requirements resolve GitLab repositories under subgroups and prefer
  the platform's provider when an `owner/name` exists under several providers.

## Impact

- `entrypoint.sh`: the logging helpers (`fail`, `warn`, `group`, `endgroup`), the `branch` /
  `repository` defaults, the outputs block, the summary block and `resolve_repository`.
- `action.yml`, `docs/configuration.md`, `openspec/specs/action-configuration/spec.md`: the two
  new inputs.
- `test/`: a platform suite for detection, defaults, annotations and sinks, and resolver tests.
- `docs/architecture.md`, `docs/reference.md`, `docs/troubleshooting.md`: the platform table and
  the resolution rules.
- No GraphQL operation changes.
- Overlaps the in-flight `fail-closed-repository-resolution` change, which also edits
  `resolve_repository`. The new resolver rules land as their own requirements so the two deltas
  do not modify the same requirement text, and that change should merge first.
