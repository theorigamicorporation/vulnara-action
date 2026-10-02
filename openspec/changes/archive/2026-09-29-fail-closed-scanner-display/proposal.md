## Why

The action leaks the scanners' stored names into places the product deliberately hides them.

`resolve_tools` answers an unrecognised `scan-tools` entry with `scan tool '<entry>' not found.
Available: <every tool name the platform offers>`. That line lands in the consumer's CI log,
which on a public repository is world-readable, and it publishes the whole roster to anyone who
mistypes a tool name. `docs/reference.md` goes further and publishes the stored name next to the
name it is meant to be shown under, which tells a reader exactly what the display name hides.

`scanner_display` falls through to the stored name for anything it does not map. The equivalent
helper in the web application deliberately does not: its comment says the fallback "is how an
internal name leaks the moment a scanner is added without a translation, which is exactly when
nobody is looking". This copy fails open, so adding a scanner to the platform leaks its stored
name into every consumer's CI log until someone edits this repository.

The resolver also prints `vulnara:   tool         <stored name> (<id>)` for every tool it
resolves, on every successful run, before any mapping is applied. That is the stored name in the
log of every run, not just a failing one.

## What Changes

- The unresolved-tool failure names the rejected entry and the tenant and points at the Vulnara
  application. It no longer enumerates what the platform offers.
- `scanner_display` fails closed: a stored name the mapping does not cover resolves to
  `Unknown scanner`, matching the web application. A scanner nobody has mapped is visibly
  unnamed rather than silently named by its image.
- `resolve_tools` emits the display name instead of the stored name, so the stored name does not
  leave the resolver and no caller can print it by accident. The `tool` line in step 3 shows the
  display name and the id the caller passed.
- `docs/reference.md` loses the stored-name-to-display-name table and documents the behaviour
  without it. `openspec/project.md` and the `scan-tools` input description stop enumerating the
  roster.

`scan-tools` keeps accepting an id or a stored name: those strings live in consumers' own
workflow files, and changing what the input accepts is a separate, announced change. Only what
the action *prints* changes here.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `scan-orchestration`: `Resolve the requested scan tools` drops the enumerated mapping and the
  raw-name fallback, and its unknown-tool scenario no longer lists the available tools. A new
  `Never print a scanner's stored name` requirement states the invariant the rest of the
  capability now depends on.

## Impact

- `entrypoint.sh`: `scanner_display` (the fallback arm), `resolve_tools` (the failure message
  and what it emits), and the step 3 `tool` info line.
- `test/config_test.sh`: the unmapped-name assertion inverts.
- `test/orchestration_test.sh`: the available-list test becomes a test that the list is absent;
  the `tool` info assertions expect display names; a new test covers an unmapped scanner.
- `docs/reference.md`, `docs/architecture.md`, `openspec/project.md`, `action.yml`.
- No change to inputs, outputs, the gate or the job summary's structure.
