## 1. Specs

- [x] 1.1 Rewrite the `scan-orchestration` selection-set paragraph: `name` is not requested, `categories` is narrowable
- [x] 1.2 Replace the by-name resolution scenarios with id-only scenarios

## 2. Tests

- [x] 2.1 Assert the catalogue request body mentions no `name`, and that one request suffices
- [x] 2.2 Assert a pinned id resolves in one request with no retry
- [x] 2.3 Assert a name-valued `scan-tools` fails naming the real cause, not the tenant
- [x] 2.4 Assert a category-valued `scan-tools` is told where a category belongs
- [x] 2.5 Keep the `categories` narrowing test, with the real gateway's rejection body

## 3. Code

- [x] 3.1 Drop `name` from `_TOOL_OPTIONAL_FIELDS` and from the selection
- [x] 3.2 Match on id only and reject a non-id entry before the catalogue is consulted
- [x] 3.3 Model the post-removal catalogue in the base fixture and the default input

## 4. Docs

- [x] 4.1 `action.yml`, `README.md`, `docs/configuration.md`, `docs/development.md`, `docs/reference.md`

## 5. Verify

- [x] 5.1 `./test/run-tests.sh`
- [x] 5.2 `openspec validate --specs --strict`
- [x] 5.3 Validate every operation the action sends against `vulnara-gateway-api` `c3648c96`
