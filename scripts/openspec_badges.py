#!/usr/bin/env python3
"""Generate OpenSpec count badges as static SVGs.

Committed to docs/badges/ and referenced with RELATIVE paths, because
raw.githubusercontent.com images do not render in private repositories.
"""
import pathlib, re, sys

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
SPECS = ROOT / "openspec" / "specs"
CHANGES = ROOT / "openspec" / "changes"
OUT = ROOT / "docs" / "badges"

def counts():
    specs = sorted(p for p in SPECS.glob("*/spec.md")) if SPECS.is_dir() else []
    reqs = sum(len(re.findall(r"(?m)^### Requirement:", p.read_text())) for p in specs)
    scen = sum(len(re.findall(r"(?m)^#### Scenario:", p.read_text())) for p in specs)
    changes = [d for d in CHANGES.iterdir() if d.is_dir() and d.name != "archive"] if CHANGES.is_dir() else []
    return len(specs), reqs, scen, len(changes)

# width per char roughly matches shields.io's 11px verdana metrics
def svg(label, value, colour):
    lw, vw = 6.5 * len(label) + 20, 6.5 * len(str(value)) + 20
    total = lw + vw
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{total:.0f}" height="20" role="img" aria-label="{label}: {value}">
<title>{label}: {value}</title>
<linearGradient id="s" x2="0" y2="100%"><stop offset="0" stop-color="#bbb" stop-opacity=".1"/><stop offset="1" stop-opacity=".1"/></linearGradient>
<clipPath id="r"><rect width="{total:.0f}" height="20" rx="3" fill="#fff"/></clipPath>
<g clip-path="url(#r)">
<rect width="{lw:.0f}" height="20" fill="#555"/>
<rect x="{lw:.0f}" width="{vw:.0f}" height="20" fill="{colour}"/>
<rect width="{total:.0f}" height="20" fill="url(#s)"/>
</g>
<g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11">
<text x="{lw/2:.0f}" y="15" fill="#010101" fill-opacity=".3">{label}</text>
<text x="{lw/2:.0f}" y="14">{label}</text>
<text x="{lw+vw/2:.0f}" y="15" fill="#010101" fill-opacity=".3">{value}</text>
<text x="{lw+vw/2:.0f}" y="14">{value}</text>
</g></svg>'''

s, r, sc, ch = counts()
OUT.mkdir(parents=True, exist_ok=True)
for name, label, value, colour in [
    ("specs", "specs", s, "#007ec6"),
    ("requirements", "requirements", r, "#007ec6"),
    ("scenarios", "scenarios", sc, "#007ec6"),
    ("open-changes", "open changes", ch, "#4c1" if ch == 0 else "#dfb317"),
]:
    (OUT / f"{name}.svg").write_text(svg(label, value, colour))
print(f"specs={s} requirements={r} scenarios={sc} open_changes={ch} -> {OUT}")
