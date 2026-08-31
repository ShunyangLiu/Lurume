#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h:h}"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/lurume-p7.XXXXXX")"
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
[[ "$fake_server" == http://127.0.0.1:* ]] || {
    print -u2 -- "P7 fake server did not report a loopback URL."
    exit 1
}

cd "$repo_root"
xcodebuild \
    -project Lurume.xcodeproj \
    -scheme Lurume \
    -configuration Debug \
    -destination 'platform=macOS' \
    test \
    -only-testing:LurumeTests/TranslationXPCIntegrationTests \
    -only-testing:TranslationServiceCoreTests/P7TranslationNetworkOperationTests \
    LURUME_TRANSLATION_FAKE_SERVER="$fake_server"
