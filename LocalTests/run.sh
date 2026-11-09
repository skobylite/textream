#!/bin/bash
# Run the fork's regression tests (no Xcode needed).
# Each LocalTests/*Tests.swift starts with lines such as:
#   // extract: Textream/Textream/ScriptQueue.swift ScriptQueue splitFrontmatter followSlot
#   // include: Textream/Textream/SpeechTextAlignment.swift
# extract.py copies the named declarations from the real sources, so the
# tests always run against the current code.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/textream-localtests"
rm -rf "$OUT"; mkdir -p "$OUT"
SDK="$(xcrun --show-sdk-path)"
status=0
for t in LocalTests/*Tests.swift; do
  name=$(basename "$t" .swift)
  dir="$OUT/$name"; mkdir -p "$dir"
  srcs=()
  n=0
  while IFS= read -r line; do
    case "$line" in
      "// extract: "*)
        set -- ${line#// extract: }
        n=$((n + 1))
        python3 -I LocalTests/extract.py "$@" > "$dir/extract$n.swift"
        srcs+=("$dir/extract$n.swift") ;;
      "// include: "*)
        f=${line#// include: }
        cp "$f" "$dir/"; srcs+=("$dir/$(basename "$f")") ;;
    esac
  done < "$t"
  cp "$t" "$dir/main.swift"
  if ! swiftc -sdk "$SDK" -target arm64-apple-macos15.0 -swift-version 5 -o "$dir/run" "${srcs[@]}" "$dir/main.swift" 2> "$dir/compile.log"; then
    echo "FAIL $name (does not compile)"; cat "$dir/compile.log"; status=1; continue
  fi
  if "$dir/run"; then echo "ok   $name"; else echo "FAIL $name"; status=1; fi
done
exit $status
