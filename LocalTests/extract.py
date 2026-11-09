#!/usr/bin/env python3
"""Copy named declarations out of a Swift source file for LocalTests.

Usage: extract.py SOURCE WRAPPER NAME [NAME ...]

Prints `enum WRAPPER { ... }` that holds each named declaration (static func,
enum, struct, static let/var) exactly as it is in SOURCE, with `private` and
`fileprivate` removed so a test can call it. The tests then run against the
real code, not a hand-made copy that can go stale.
"""
import re
import sys

src_path, wrapper, names = sys.argv[1], sys.argv[2], sys.argv[3:]
lines = open(src_path, encoding="utf-8").read().split("\n")

def find(name):
    pat = re.compile(
        r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
        r"(?:(?:private|fileprivate|internal|public|nonisolated|static|final)\s+)*"
        r"(?:func|enum|struct|let|var)\s+" + re.escape(name) + r"\b")
    hits = [i for i, l in enumerate(lines) if pat.match(l)]
    if not hits:
        sys.exit(f"extract.py: {name} not found in {src_path}")
    return hits[0]

def capture(i):
    out, depth, started, in_str, j = [], 0, False, False, i
    while j < len(lines):
        line = lines[j]
        out.append(line)
        k = 0
        while k < len(line):
            c = line[k]
            if in_str:
                if c == "\\":
                    k += 2
                    continue
                if c == '"':
                    in_str = False
            else:
                if line.startswith("//", k):
                    break
                if c == '"':
                    in_str = True
                elif c == "{":
                    depth += 1
                    started = True
                elif c == "}":
                    depth -= 1
            k += 1
        in_str = False  # Swift single-line strings never span lines
        if started and depth == 0:
            break
        if not started and j == i and "{" not in line and not line.rstrip().endswith(("(", ",", "->")):
            break  # one-line declaration such as `static let x = 4`
        j += 1
    out[0] = re.sub(r"\b(private|fileprivate)\s+", "", out[0])
    return out

print(f"enum {wrapper} {{")
for n in names:
    print("\n".join(capture(find(n))))
print("}")
