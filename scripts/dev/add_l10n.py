"""Adds keys to BobbCore/L10n/L10n.swift: a `case` line in `Key` and the
English/Italian pair in the table. Usage:

    python3 scripts/dev/add_l10n.py <section> <<'KEYS'
    keyName|English text|Testo italiano
    KEYS
"""

import sys
from pathlib import Path

path = Path(__file__).resolve().parents[2] / "BobbApp/Sources/BobbCore/L10n/L10n.swift"
section = sys.argv[1]
rows = [line.split("|") for line in sys.stdin.read().splitlines() if line.strip()]
source = path.read_text()
existing = set()
for name, *_ in rows:
    if f".{name}:" in source:
        existing.add(name)
rows = [r for r in rows if r[0] not in existing]
if not rows:
    sys.exit(0)


def swift(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


names = [r[0] for r in rows]
lines = []
line = "        case "
for i, name in enumerate(names):
    piece = name + (", " if i < len(names) - 1 else "")
    if len(line) + len(piece) > 118:
        lines.append(line.rstrip())
        line = "             "
    line += piece
lines.append(line.rstrip())
case_block = f"        // {section}\n" + "\n".join(lines) + "\n"
anchor = "        // misc\n"
assert anchor in source
source = source.replace(anchor, case_block + anchor, 1)

entries = "\n".join(f"        .{name}: ({swift(en)}, {swift(it)})," for name, en, it in rows) + "\n\n"
anchor = "        .genericCancel:"
assert anchor in source
source = source.replace(anchor, entries + anchor, 1)
path.write_text(source)
print(f"added {len(rows)} keys")
