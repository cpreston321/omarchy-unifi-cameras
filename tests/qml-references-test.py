#!/usr/bin/env python3
"""Every `root.<name>` in Panel.qml must resolve to something declared.

An undeclared name is not a QML error. Binding `visible` to an undefined
expression leaves the property at its default — which for `visible` is true —
so a control guarded by a name that does not exist is permanently on screen.
That is how the setup panel came to show its API key field before a console
was even connected.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Panel.qml").read_text(encoding="utf-8")

declared = set(re.findall(r"(?:readonly\s+)?property\s+\w+(?:<[^>]+>)?\s+(\w+)", source))
declared |= set(re.findall(r"function\s+(\w+)\s*\(", source))
# Inherited from the Panel base and QQuickItem.
declared |= {
    "opened", "bar", "settings", "controller", "popoutSwitchClosing",
    "close", "open", "toggle", "moduleName", "ipcTarget", "manageIpc",
}

used = set(re.findall(r"\broot\.(\w+)", source))
missing = sorted(used - declared)

if missing:
    print("FAIL - undeclared root references: " + ", ".join(missing))
    sys.exit(1)
print(f"ok - all {len(used)} root references are declared")
