const core = require('@actions/core');
const github = require('@actions/github');
const fs = require('fs');
const { execSync } = require('child_process');


function get_home_directory() {
    return process.env.HOME || process.env.USERPROFILE;
}

function check_service_account_directory() {
    const home_directory = get_home_directory();
    if (!fs.existsSync(`${home_directory}/.config/vulnara/sa`)) {
        fs.mkdirSync(`${home_directory}/.config/vulnara/sa`, { recursive: true });
    }
}

function validate_service_account_content(service_account) {
    try {
        JSON.parse(service_account);
    } catch (error) {
        throw new Error("Invalid service account content");
    }

    if (!service_account.username || !service_account.password) {
        throw new Error("Invalid service account content");
    }
}

function set_service_account(service_account) {
    check_service_account_directory();
    validate_service_account_content(service_account);
    try {
        fs.writeFileSync(`${get_home_directory()}/.config/vulnara/sa/service_account.json`, service_account);
    } catch (error) {
        throw new Error("Failed to write service account");
    }
}

function prepare_args(repository_id, git_token_id, scan_image, docker_scan_tool_id, branch, create_issue, auto_remediate) {
    const args = [];
    if (repository_id) {
        args.push(`--repository-id ${repository_id}`);
    }
    if (git_token_id) {
        args.push(`--git-token-id ${git_token_id}`);
    }
    if (scan_image) {
        args.push(`--scan-image ${scan_image}`);
    }
    if (docker_scan_tool_id) {
        args.push(`--docker-scan-tool-id ${docker_scan_tool_id}`);
    }
    if (branch) {
        args.push(`--branch ${branch}`);
    }
    if (create_issue) {
        args.push(`--create-issue ${create_issue}`);
    }
    if (auto_remediate) {
        args.push(`--auto-remediate ${auto_remediate}`);
    }
    
    return args;
}

function run_scan(args) {
    const command = `vulnara-cli ${args.join(' ')}`;
    try {
        execSync(command, { cwd: "/usr/local/bin" });
    } catch (error) {
        throw new Error("Failed to run scan");
    }
}

try{
    const repository_id = core.getInput('repository_id', { required: true });
    const git_token_id = core.getInput('git_token_id', { required: false });
    const scan_image = core.getInput('scan_image', { required: false });
    const docker_scan_tool_id = core.getInput('docker_scan_tool_id', { required: false });
    const branch = core.getInput('branch', { required: false });
    const create_issue = core.getInput('create_issue', { required: true });
    const auto_remediate = core.getInput('auto_remediate', { required: true });
    const service_account = core.getInput('service_account', { required: true });
    
    if (scan_image == null && docker_scan_tool_id == null) {
        throw new Error("Either scan_image or docker_scan_tool_id must be provided")
    }
    if (scan_image != null && docker_scan_tool_id != null) {
        throw new Error("Cannot specify both scan_image and docker_scan_tool_id")
    }
    
    set_service_account(service_account);
    const args = prepare_args(repository_id, git_token_id, scan_image, docker_scan_tool_id, branch, create_issue, auto_remediate);
    run_scan(args);

} catch (error) {
    core.setFailed(error.message);
}
