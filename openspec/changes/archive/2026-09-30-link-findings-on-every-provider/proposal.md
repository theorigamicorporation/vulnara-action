## Why

Vulnara now scans Bitbucket, Azure DevOps and Forgejo/Codeberg repositories. The findings table
only knew GitLab's `/-/blob/` form and used GitHub's `/blob/` for everything else, so links on
the new providers 404. Azure repository URLs also lacked the `_git` segment, and a `cloneUrl`
fallback could carry credentials into the job summary.

## What changes

- Source links per provider, using the platform URL shapes at the scanned commit.
- Azure DevOps browsing URL is `<htmlUrl>/<project>/_git/<repo>`.
- Credentials are stripped from a `cloneUrl` fallback.
- The action stays GitHub Actions only. No Bitbucket or Azure pipeline wrappers.
