## Context

`entrypoint.sh` is GitHub-shaped in exactly five places: the `input()` helper, the `branch` and
`repository` defaults (`GITHUB_REF_NAME`, `GITHUB_REPOSITORY`), the annotation helpers (`fail`,
`warn`, `group`, `endgroup`), the outputs block (`GITHUB_OUTPUT`) and the summary block
(`GITHUB_STEP_SUMMARY`). Everything between them (authentication, GraphQL, polling, the gate,
the Markdown itself) is plain Bash with `curl` and `jq` and runs anywhere the image runs.

Each CI system Vulnara's providers come with can run a container, and each has its own way to
reuse a step:

| Platform | Reuse mechanism | Self-service listing | Order |
|---|---|---|---|
| GitHub | Marketplace action | GitHub Marketplace | today |
| GitLab | CI/CD component | GitLab CI/CD Catalog (gitlab.com) | this change, then the component |
| Bitbucket | Pipe (`docker://<image>`) | no, Atlassian curates the pipes directory | later |
| Forgejo / Codeberg | `uses:` with a full URL | none | later |
| Azure DevOps | Marketplace extension task | Visual Studio Marketplace, verified publisher | last |

The platforms are added one at a time. This change builds the layer and fills it for GitHub and
GitLab only, so the shape is proven against one real second platform before three more are
added to it.

## Goals / Non-Goals

**Goals:**

- One image and one script, with a platform layer that a later platform extends by adding rows,
  not by restructuring.
- Zero change on GitHub: same annotations, same outputs, same summary, same defaults.
- The GitLab component reduces to "map inputs to `INPUT_*`, run the image, publish
  `report-dir`".

**Non-Goals:**

- The GitLab CI/CD component itself, and publishing the image to a public registry. Both are the
  next changes.
- Bitbucket, Forgejo and Azure DevOps. Each gets its own change.
- A merge request comment or a GitLab Code Quality report. A merge request note needs an API
  token the job does not have (`CI_JOB_TOKEN` cannot post notes), and Code Quality is its own
  report format. The summary artifact plus the collapsed log section is the baseline.
- Neutralising logging commands in untrusted text. It is a live issue on GitHub today and ships
  as its own fix, independent of this change. GitLab has no logging commands to inject.
- Moving `create-issue` / `auto-remediate`. They are platform-side features and already
  provider-agnostic in the API.

## Decisions

**Detect from the environment, with an override.** `GITHUB_ACTIONS=true` and `GITLAB_CI=true` are
the stable markers. GitHub is checked first so a GitHub run never changes behaviour. The
`ci-platform` input covers the cases detection gets wrong. An unknown value fails rather than
falling back, so a typo cannot change where outputs go. Later platforms add their markers to the
order; Forgejo will have to go before GitHub, because Forgejo runners also set
`GITHUB_ACTIONS=true`.

**One helper layer, chosen once.** `detect_platform` runs before any input is read, and sets
`CI_PLATFORM`. `fail`, `warn`, `group`, `endgroup`, `emit_outputs` and `emit_summary` branch on
it. The rest of the script never tests the platform.

**GitLab merge request branch first.** In a merge request pipeline `CI_COMMIT_BRANCH` is unset
and `CI_MERGE_REQUEST_SOURCE_BRANCH_NAME` names the branch, so that is read first. A tag
pipeline has neither and fails with the existing `branch could not be determined`, which is the
right answer: Vulnara scans branches.

**Underscore output names off GitHub.** A GitLab dotenv report rejects dashes. `VULNARA_` plus
the upper-cased name is unambiguous in a job that already has other variables, and is what the
component exposes to later jobs. On GitHub the `action.yml` names stay.

**Files for GitLab.** GitLab has no step-summary API a container can write to. `outputs.env` and
`summary.md` under `$CI_PROJECT_DIR/.vulnara` are inside the artifact root, so the component
publishes them with `artifacts: reports: dotenv:` and `artifacts: paths:`. A dotenv report only
reaches later jobs and only single-line values; every output is single-line. The summary is also
printed in a collapsed section, because an artifact is a click away and the log is not.

**Nested namespaces in the resolver.** Vulnara's GitLab proxy stores a subgroup project with the
entity name `group/sub` (`gitlab_proxy.py` URL-encodes `{git_entity_name}/{repository_name}`).
The resolver matches the first segment of `repository`, so `CI_PROJECT_PATH=group/sub/project`
never matches and today falls through to the first returned item. Taking the owner as
everything before the last `/` is identical for two-segment input and correct for subgroups.

**Prefer the platform's provider.** The non-Azure match is on name and owner only, so a tenant
with `acme/widgets` on both GitHub and GitLab resolves whichever the gateway returns first. With
two platforms that becomes a real case. A preference, not a filter: someone scanning a mirrored
repository by passing `repository` explicitly still resolves when only the other provider holds
it.

## Risks / Trade-offs

- [Detection picks the wrong platform] -> `ci-platform` overrides it, and the banner prints the
  platform so a wrong pick is visible in the first lines of the log.
- [The GitLab section marker format is from memory] -> task 1 checks it against the GitLab docs.
  A wrong marker only loses the collapsing; the text still prints.
- [The resolver rules and `fail-closed-repository-resolution` both touch `resolve_repository`]
  -> that change merges first and this one rebases. The spec deltas do not conflict.

## Migration Plan

None for consumers. GitHub behaviour is unchanged, so this ships as a MINOR release and moves
`v1`. The GitLab component needs the image in a public registry, which is the next change.

## Open Questions

- Which gitlab.com group hosts the component project, and under what name. Needed by the
  component change, not this one.
