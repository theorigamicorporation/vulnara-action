## Context

`resolve_repository` cannot query Vulnara by `owner/name`: the `repositories` list filter only
exposes `repositoryName`, and the owner lives on the polymorphic `gitEntity` (an `Organization`
or a `GitUser`). The action therefore over-fetches by name and disambiguates client-side, and
the current spec closes the gap by falling back to the first item.

That fallback is invisible at runtime. Step 2 rebuilds `REPO_FULLNAME` from the resolved
entity, so the banner and the job summary show the repository that was actually scanned,
formatted exactly like a correct resolution. Nothing tells the operator that the owner they
asked for was not the owner they got.

## Goals / Non-Goals

**Goals:**

- Never scan or gate on a repository whose owner does not match the `repository` input.
- Make the failure diagnosable without opening Vulnara: say which owners came back.
- Keep the change inside `resolve_repository`; no new inputs, outputs or GraphQL operations.

**Non-Goals:**

- Server-side filtering by owner. That needs a gateway filter on `gitEntity.name` and belongs
  in the platform, not here.
- An escape hatch input (`allow-owner-mismatch` or similar). Adding one re-creates the hazard
  behind a flag, and no user has asked for it.
- Any change to how a matched repository is reported.

## Decisions

**Fail rather than warn.** A `::warning::` keeps the wrong scan running and still exits 0 on a
clean result, which is the same failure mode as A3.2: an annotation nobody reads on a green
job. The gate exists to stop the build, so it stops.

**Fail on a single non-matching item too.** The alternative, "fall back only when exactly one
item comes back", is tempting because the common cause is a renamed git entity rather than a
genuine collision. It is still a guess, and it fails in exactly the case the operator cannot
check: a tenant that holds one `widgets` today and two next month behaves differently on the
same workflow file. One rule, always the same.

**Name the returned owners in the error.** The realistic cause is an entity recorded in Vulnara
under a different name, so the fix is a rename in Vulnara. Listing `gitEntity.name` for every
returned item turns the failure into an instruction. The list is bounded by how many
same-named repositories a tenant holds, so it needs no truncation.

**Keep the empty-result message as it is.** "Not found" and "found under a different owner" are
different operator actions (add the repository vs. fix the entity name), so they stay separate
messages. Nothing about the empty case changes.

## Risks / Trade-offs

- A tenant whose git entity name legitimately differs from the GitHub owner starts failing on a
  workflow that used to pass → the failure names both the requested owner and the returned
  ones, and the fix is a one-time rename in Vulnara. This is a MAJOR bump; it reaches consumers
  only when the `v1` tag moves.
- Slightly more work at resolution time (a second `jq` pass to collect the owner list) → this
  runs once per job, against a result set of a handful of items.

## Migration Plan

The change ships behind the major tag: `@v1` consumers see nothing until `v2` is cut. The
release notes carry the `BREAKING CHANGE` footer and the remediation (rename the git entity in
Vulnara so its name matches the git owner). Rollback is reverting the single commit; there is
no state to migrate.

## Open Questions

- Should the gateway grow a `gitEntity.name` filter so the action can resolve server-side? That
  removes the client-side disambiguation entirely, but it is a platform change and does not
  block this one.
