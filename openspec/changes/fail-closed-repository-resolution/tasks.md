## 1. Tests

- [ ] 1.1 Replace `test_repository_falls_back_to_the_first_item_when_no_owner_matches` in
      `test/orchestration_test.sh` with a test asserting the run fails, the message names the
      requested `owner/name`, the tenant and the returned owner, and no `startRepositoryScan`
      is issued.
- [ ] 1.2 Add a test for a single returned item under a different owner, proving the failure
      does not depend on the result set holding more than one candidate.
- [ ] 1.3 Move the `cloneUrl` browsing-URL and `programmingLanguage: null` assertions the old
      test carried onto a fixture whose owner matches, so that coverage is not lost.
- [ ] 1.4 Run `./test/run-tests.sh` and confirm the new tests fail for the right reason.

## 2. Implementation

- [ ] 2.1 Drop the `// (.repositories.items[0])` fallback from the `jq` selection in
      `resolve_repository`.
- [ ] 2.2 Distinguish an empty result set from a non-matching one, keeping the existing
      not-found message for the empty case.
- [ ] 2.3 Emit the new failure with the requested `owner/name`, the tenant and the list of
      returned `gitEntity.name` values.
- [ ] 2.4 Run `./test/run-tests.sh` and `shellcheck -S warning entrypoint.sh` clean.

## 3. Documentation

- [ ] 3.1 Remove the "The wrong repository is scanned" known issue from
      `docs/troubleshooting.md` and add a common-failure entry for the new message.
- [ ] 3.2 Check `docs/architecture.md` and `docs/reference.md` for statements about the
      fallback and update them.
- [ ] 3.3 Commit with a `BREAKING CHANGE:` footer naming the remediation.
