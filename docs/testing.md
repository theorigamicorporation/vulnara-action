# Testing

[Back to the README](../README.md)

```bash
./test/run-tests.sh
```

**72 tests.** They need only `bash` and `jq`, both already in the action image. `curl` and `sleep`
are stubbed on `PATH`, so nothing reaches the network and no Vulnara account is required. See
[test/README.md](../test/README.md) for the layout and how to add a case.

CI runs shellcheck, the suite, and a Docker image build on every push and pull request.

Beyond the suite, a change is also verified by three things.

## 1. Lint

```bash
shellcheck -S warning entrypoint.sh
```

Must be clean. `entrypoint.sh` runs under `set -euo pipefail`, and most of what shellcheck
catches here (unquoted expansions, masked return values) is exactly the class of bug that turns
a gate failure into a silent pass.

## 2. Build

```bash
docker build -t vulnara-action:dev .
```

The action is a container action, so a broken `Dockerfile` fails every consumer at run time
rather than at review time.

## 3. An end-to-end run against a non-production Vulnara

Point a workflow at your branch and override the environment, as described in
[Development](development.md#running-against-a-non-production-vulnara). Cover at least:

| Case | Expect |
|---|---|
| A repository with no findings | Job passes, `highest-severity=none`, `passed=true` |
| Findings below `fail-on` | Job passes, summary lists the findings |
| Findings at or above `fail-on` | Job fails with `scan gate failed`, `passed=false` |
| Two scanners at once | Two scan ids in `scan-result-ids`, two rows in the summary |
| An unknown tool name | See the [exit-0 caveat](troubleshooting.md#a-tool-resolution-failure-passes-the-gate); today the job passes, which is the bug |

## What a test has to satisfy

The behaviour is written down in [`openspec/specs/`](../openspec/specs/): 43 scenarios across
15 requirements in three capabilities, each phrased as WHEN/THEN against observable output,
including the exact strings the action prints. When an automated suite lands, each test should
carry a `# spec:` comment naming the capability, requirement and scenario it covers, so a
failing test points straight at the requirement it breaks.

Anything that stands in for the platform must stay free of real credentials, hostnames and
tenant ids. This repository is public: use `example.test` hostnames and obviously fake ids.
