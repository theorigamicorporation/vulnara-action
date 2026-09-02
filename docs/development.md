# Development

[Back to the README](../README.md)

There is no build step and no package manager. `entrypoint.sh` is the whole implementation,
`action.yml` is the interface, and the `Dockerfile` is five lines of Alpine.

## Local checks

```bash
just ci      # shellcheck, the offline test suite and the image build, as tests.yml runs them
just specs   # openspec validate --specs --strict, as openspec.yml runs it
just badges  # python3 scripts/openspec_badges.py .
```

The badge script regenerates `docs/badges/*.svg` from `openspec/`. The `OpenSpec Badges`
workflow runs it on `main` and commits the result, so run it locally only to check it is clean.

Run `just` for the full recipe list. The pieces `just ci` runs, if you want them one at a time:

```bash
shellcheck -S warning entrypoint.sh test/run-tests.sh test/lib/harness.sh test/stubs/* test/*_test.sh
./test/run-tests.sh
docker build -t vulnara-action:dev .
```

`tests.yml` lints the test sources as well as `entrypoint.sh`, so `shellcheck entrypoint.sh`
alone can be clean while CI is red.

## Running against a non-production Vulnara

Point a workflow at your branch and override the four environment inputs together:

```yaml
      - uses: theorigamicorporation/vulnara-action@my-branch
        with:
          service-account: ${{ vars.VULNARA_SERVICE_ACCOUNT }}
          token: ${{ secrets.VULNARA_TOKEN }}
          tenant: my-tenant
          scan-tools: AEGIS
          gateway-url: https://gateway.example.test/graphql
          app-url: https://app.example.test
          token-url: https://auth.example.test/application/o/token/
          oauth-client-id: <non-prod client id>
```

For a gateway to develop against, see
[vulnara-dev](https://github.com/theorigamicorporation/vulnara-dev).

## Conventions

- Build every GraphQL body with `jq -n` so values are JSON-encoded. Never interpolate an input
  into a query string.
- Read inputs through the `input()` helper, never `${INPUT_...}`. GitHub exposes container
  action inputs with dashes preserved (`INPUT_SERVICE-ACCOUNT`), which Bash cannot address.
- Send user-facing lines to stderr with the `vulnara:` prefix, through `log`, `step`, `info`,
  `ok` or `warn`.
- Use `::error::` and `::warning::` for anything that should surface as a GitHub annotation.
- Keep every endpoint overridable: a production default in both `action.yml` and
  `entrypoint.sh`, plus an input to replace it.
- Never write a credential to `GITHUB_OUTPUT`, `GITHUB_STEP_SUMMARY` or the log. The JWT stays
  in memory.

## Changing the interface

A new input has to land in `action.yml`, in [Configuration](configuration.md) and in
[`openspec/specs/action-configuration/spec.md`](../openspec/specs/action-configuration/spec.md)
in the same pull request. Behaviour is specified before it is implemented: see the OpenSpec
workflow in [CONTRIBUTING.md](../CONTRIBUTING.md).

## Releasing

The action is consumed by tag, for example `theorigamicorporation/vulnara-action@v1`. Cutting a
patch tag and moving the `v1` major tag onto it is what actually ships a change to consumers.
