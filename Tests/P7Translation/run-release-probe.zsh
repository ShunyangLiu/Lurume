#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h:h}"
probe_app="${1:-$repo_root/build/P7Checkpoint1/ProbeDerivedData/Build/Products/Release/LurumeTranslationProbe.app}"
probe_binary="$probe_app/Contents/MacOS/LurumeTranslationProbe"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/lurume-p7-release.XXXXXX")"
server_output="$temp_root/server.out"
server_error="$temp_root/server.err"

cleanup() {
    if [[ -n "${server_pid:-}" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$temp_root"
}
trap cleanup EXIT INT TERM

[[ -x "$probe_binary" ]] || {
    print -u2 -- "Release probe is missing: $probe_binary"
    exit 1
}

python3 "$repo_root/Tests/P7Translation/fake_openai_server.py" \
    >"$server_output" 2>"$server_error" &
server_pid=$!

for _ in {1..100}; do
    [[ -s "$server_output" ]] && break
    kill -0 "$server_pid" 2>/dev/null || {
        print -u2 -- "P7 fake server exited before becoming ready."
        sed -n '1,120p' "$server_error" >&2
        exit 1
    }
    sleep 0.05
done

fake_server="$(sed -n '1p' "$server_output")"
probe_output="$($probe_binary "$fake_server/stream")"
python3 -c '
import json, sys
result = json.loads(sys.argv[1])
assert result["terminal"] == "completed", result
assert result["text"] == "分块译文", result
assert 0 <= result["coldStartMilliseconds"] < 5000, result
' "$probe_output"

reclaimed_milliseconds="not-observed"
for attempt in {1..50}; do
    if ! ps -axo comm= | rg -F -q '/LurumeTranslationService'; then
        reclaimed_milliseconds=$((attempt * 100))
        break
    fi
    sleep 0.1
done

print -r -- "$probe_output"
print -r -- "idleReclaimedWithinMilliseconds=$reclaimed_milliseconds"
