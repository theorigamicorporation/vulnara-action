_col := "RED=$'\\e[31m'; GREEN=$'\\e[32m'; YELLOW=$'\\e[33m'; CYAN=$'\\e[36m'; BOLD=$'\\e[1m'; DIM=$'\\e[2m'; NC=$'\\e[0m'"

repo_dir := justfile_directory()

tag := "vulnara-action:dev"

# The exact source list CI passes to shellcheck.
_shell_sources := "entrypoint.sh test/run-tests.sh test/lib/harness.sh test/stubs/* test/*_test.sh"

# show available recipes (default)
help:
    #!/usr/bin/env bash
    {{_col}}
    printf "${BOLD}vulnara-action${NC} - the Vulnara scan GitHub Action\n\n"
    printf "${BOLD}Usage:${NC}  just <recipe>\n\n"
    printf "${BOLD}Core${NC}\n"
    printf "  ${GREEN}setup${NC}    check that bash, jq, shellcheck and docker are present\n"
    printf "  ${GREEN}build${NC}    docker build the action image as {{tag}}\n"
    printf "\n${BOLD}Quality${NC}\n"
    printf "  ${YELLOW}lint${NC}     shellcheck -S warning over entrypoint.sh and the test sources\n"
    printf "\n${BOLD}Test${NC}\n"
    printf "  ${YELLOW}test${NC}     ./test/run-tests.sh, offline, curl and sleep are stubbed\n"
    printf "\n${BOLD}Security${NC}\n"
    printf "  ${RED}trivy${NC}    filesystem scan, honouring trivy.yaml\n"
    printf "\n${BOLD}Specs${NC}\n"
    printf "  ${CYAN}specs${NC}    openspec validate --specs --strict\n"
    printf "  ${CYAN}badges${NC}   regenerate docs/badges from openspec/\n"
    printf "\n${BOLD}CI${NC}\n"
    printf "  ${BOLD}ci${NC}       lint, test, build\n"
    printf "\n${DIM}There is no build step and nothing to install: bash and jq run the suite,${NC}\n"
    printf "${DIM}shellcheck lints it, docker builds the image.${NC}\n"

# check that the tools this repository needs are installed
setup:
    #!/usr/bin/env bash
    {{_col}}
    missing=0
    for tool in bash jq shellcheck docker; do
        if command -v "$tool" >/dev/null 2>&1; then
            printf "${GREEN}  [ok]${NC}       %s\n" "$tool"
        else
            printf "${RED}  [missing]${NC}  %s\n" "$tool"
            missing=$((missing+1))
        fi
    done
    printf "\n"
    if [ "$missing" -eq 0 ]; then
        printf "${GREEN}${BOLD}Nothing to install.${NC}\n"
    else
        printf "${YELLOW}%d tool(s) missing. bash and jq run the suite, shellcheck lints it,\n" "$missing"
        printf "docker builds the image. Install them with your package manager.${NC}\n"
        exit 1
    fi

# build the action image locally
build:
    @docker build -t {{tag}} "{{repo_dir}}"

# shellcheck the action and the test sources, exactly as CI does
lint:
    #!/usr/bin/env bash
    {{_col}}
    set -e
    cd "{{repo_dir}}"
    shellcheck -S warning {{_shell_sources}}
    printf "${GREEN}  [ok]${NC} shellcheck clean\n"

# run the offline shell test suite
test:
    @cd "{{repo_dir}}" && ./test/run-tests.sh

# scan the working tree for vulnerabilities, secrets and misconfiguration
trivy:
    #!/usr/bin/env bash
    {{_col}}
    cd "{{repo_dir}}"
    if command -v trivy >/dev/null 2>&1; then
        trivy fs --scanners secret,vuln,misconfig .
    else
        docker run --rm -v "{{repo_dir}}:/workspace" -w /workspace \
            docker.io/aquasec/trivy:latest \
            fs --scanners secret,vuln,misconfig /workspace
    fi

# validate the OpenSpec specifications
specs:
    openspec validate --specs --strict

# regenerate the OpenSpec count badges under docs/badges
badges:
    @cd "{{repo_dir}}" && python3 scripts/openspec_badges.py .

# the local gate: lint, test, build, exactly what CI runs
ci: lint test build
    #!/usr/bin/env bash
    {{_col}}
    printf "${GREEN}${BOLD}Local gate passed.${NC}\n"
