## 1. Verify assumptions

- [ ] 1.1 Check the GitLab `section_start` / `section_end` marker format and the allowed section
      id characters against the GitLab job log docs, and adjust the `ci-platform` spec if they
      differ.
- [ ] 1.2 Check the GitLab dotenv report limits (variable count, value size, allowed names).

## 2. Tests

Each test carries a `# spec:` comment naming its capability, requirement and scenario.

- [ ] 2.1 Add `test/platform_test.sh` covering every `Detect the CI platform` scenario,
      including the override and the unknown-value failure.
- [ ] 2.2 Cover every `Default the branch and repository from the platform` scenario.
- [ ] 2.3 Cover the GitLab annotation and section syntax, and assert GitHub output is unchanged
      against the existing suite.
- [ ] 2.4 Cover the output and summary sinks: dotenv names and `summary.md` on GitLab, the
      collapsed summary section, the `report-dir` override, and nothing written on `none`.
- [ ] 2.5 Extend the credential test so no file under `report-dir` contains the token or the JWT.
- [ ] 2.6 Add the nested-namespace and provider-preference resolver tests to
      `test/orchestration_test.sh`.
- [ ] 2.7 Run `./test/run-tests.sh` and confirm the new tests fail for the right reason.

## 3. Implementation

- [ ] 3.1 Add `detect_platform` and call it before the first `input` read; validate
      `ci-platform`; print the platform in the banner.
- [ ] 3.2 Replace the `GITHUB_REF_NAME` / `GITHUB_REPOSITORY` defaults with a per-platform
      `default_branch` / `default_repository`.
- [ ] 3.3 Make `fail`, `warn`, `group` and `endgroup` render per platform.
- [ ] 3.4 Resolve `report-dir`, and replace the outputs and summary blocks with
      `emit_outputs` / `emit_summary` that write to the platform sink. Build the summary once
      into a temp file so its content is the same everywhere.
- [ ] 3.5 In `resolve_repository`, take the non-Azure owner as everything before the last `/`,
      and prefer the candidate whose `gitType` matches the platform's provider.
- [ ] 3.6 Add `ci-platform` and `report-dir` to `action.yml` with empty defaults.
- [ ] 3.7 Run `just ci` and `just specs` clean.

## 4. Documentation

- [ ] 4.1 Add both inputs and the GitLab environment variables to `docs/configuration.md`.
- [ ] 4.2 Add the platform table and the sink table to `docs/architecture.md` and
      `docs/reference.md`; document nested GitLab namespaces and the provider preference in
      "Resolving the repository".
- [ ] 4.3 Update the README inputs table, without promising a GitLab component that has not
      shipped.
- [ ] 4.4 Update `docs/development.md` conventions: annotations go through the helpers, never a
      literal `::error::`.
- [ ] 4.5 Commit as `feat(platform): ...` (MINOR).

## 5. Follow-up changes (not in this change)

- [ ] 5.1 Publish the image to ghcr on each tag, multi-arch (amd64, arm64).
- [ ] 5.2 GitLab CI/CD component project in our gitlab.com group, published to the CI/CD Catalog.
- [ ] 5.3 Neutralise logging commands in untrusted log text (`fix`, GitHub today).
- [ ] 5.4 Bitbucket, then Forgejo, then Azure DevOps, each as its own platform change.
