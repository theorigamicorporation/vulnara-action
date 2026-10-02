## 1. Specs

- [x] 1.1 Point the resolver failures at `vulnara docker_scan_tools` and the `dockerScanTools` query

## 2. Code and tests

- [x] 2.1 Replace the application pointer in both failures and in the `scan-tools` description
- [x] 2.2 Assert both failures name the CLI command and the query
- [x] 2.3 Upper-case the fixture's categories

## 3. Verify

- [x] 3.1 `./test/run-tests.sh`, shellcheck, docker build
