#!/bin/zsh

set -euo pipefail

lurume_test_dir="${0:A:h}"
lurume_repo_root="${lurume_test_dir:h:h}"
source "$lurume_repo_root/Scripts/lib/release-common.zsh"

lurume_tmp_base="${TMPDIR:-/tmp}"
lurume_work_dir="$(mktemp -d "$lurume_tmp_base/lurume-release-tests.XXXXXX")"
lurume_cleanup_tests() {
    case "$lurume_work_dir" in
        "$lurume_tmp_base"/lurume-release-tests.*) rm -rf -- "$lurume_work_dir" ;;
    esac
}
trap lurume_cleanup_tests EXIT INT TERM

expect_failure() {
    local lurume_name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        print -u2 "应失败但通过：$lurume_name"
        exit 1
    fi
    print "已拒绝：$lurume_name"
}

lurume_require_semver '1.2.3'
lurume_require_build_number '42'
expect_failure '非法语义版本' lurume_require_semver '1.2'
expect_failure '非递增整数构建号' lurume_require_build_number '0'

print '# Lurume v1.2.3' > "$lurume_work_dir/notes.md"
lurume_verify_release_notes_heading "$lurume_work_dir/notes.md" '1.2.3'
expect_failure '更新说明版本漂移' lurume_verify_release_notes_heading "$lurume_work_dir/notes.md" '1.2.4'

mkdir -p "$lurume_work_dir/artifacts/release-notes"
print 'dmg fixture' > "$lurume_work_dir/artifacts/Lurume-1.2.3.dmg"
print '<rss />' > "$lurume_work_dir/artifacts/appcast.xml"
cp "$lurume_work_dir/notes.md" "$lurume_work_dir/artifacts/release-notes/Lurume-1.2.3.md"

jq -n \
    --arg dmg_hash "$(lurume_sha256 "$lurume_work_dir/artifacts/Lurume-1.2.3.dmg")" \
    --argjson dmg_length "$(lurume_file_size "$lurume_work_dir/artifacts/Lurume-1.2.3.dmg")" \
    --arg appcast_hash "$(lurume_sha256 "$lurume_work_dir/artifacts/appcast.xml")" \
    --argjson appcast_length "$(lurume_file_size "$lurume_work_dir/artifacts/appcast.xml")" \
    --arg notes_hash "$(lurume_sha256 "$lurume_work_dir/artifacts/release-notes/Lurume-1.2.3.md")" \
    --argjson notes_length "$(lurume_file_size "$lurume_work_dir/artifacts/release-notes/Lurume-1.2.3.md")" \
    '{
        schema_version: 1,
        files: {
            dmg: {path: "Lurume-1.2.3.dmg", sha256: $dmg_hash, length: $dmg_length},
            appcast: {path: "appcast.xml", sha256: $appcast_hash, length: $appcast_length},
            release_notes: {path: "release-notes/Lurume-1.2.3.md", sha256: $notes_hash, length: $notes_length}
        }
    }' > "$lurume_work_dir/artifacts/manifest.json"

lurume_verify_manifest_files "$lurume_work_dir/artifacts"
print 'manifest tamper' >> "$lurume_work_dir/artifacts/appcast.xml"
expect_failure '发布后文件篡改' lurume_verify_manifest_files "$lurume_work_dir/artifacts"

cp "$lurume_work_dir/artifacts/manifest.json" "$lurume_work_dir/path-traversal.json"
jq '.files.dmg.path = "../outside.dmg"' "$lurume_work_dir/path-traversal.json" > "$lurume_work_dir/artifacts/manifest.json"
expect_failure '清单路径越界' lurume_verify_manifest_files "$lurume_work_dir/artifacts"

mkdir -p "$lurume_work_dir/preflight/Scripts/lib" \
    "$lurume_work_dir/preflight/release-notes" \
    "$lurume_work_dir/preflight/Lurume.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
cp "$lurume_repo_root/Scripts/prepare-release" "$lurume_work_dir/preflight/Scripts/prepare-release"
cp "$lurume_repo_root/Scripts/lib/release-common.zsh" "$lurume_work_dir/preflight/Scripts/lib/release-common.zsh"
print '# Lurume v0.0.2' > "$lurume_work_dir/preflight/release-notes/v0.0.2.md"
cat > "$lurume_work_dir/preflight/project.yml" <<'EOF'
targets:
  Lurume:
    settings:
      base:
        CURRENT_PROJECT_VERSION: 2
        MARKETING_VERSION: 0.0.2
EOF
cat > "$lurume_work_dir/preflight/Lurume.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" <<'EOF'
{"pins":[{"identity":"sparkle","state":{"version":"2.9.6"}}]}
EOF
git -C "$lurume_work_dir/preflight" init -q -b main
git -C "$lurume_work_dir/preflight" config user.name 'Lurume Release Test'
git -C "$lurume_work_dir/preflight" config user.email 'release-test@invalid.example'
git -C "$lurume_work_dir/preflight" add .
git -C "$lurume_work_dir/preflight" commit -q -m baseline
git -C "$lurume_work_dir/preflight" tag v0.0.2

sed -i '' 's/CURRENT_PROJECT_VERSION: 2/CURRENT_PROJECT_VERSION: 3/' "$lurume_work_dir/preflight/project.yml"
sed -i '' 's/MARKETING_VERSION: 0.0.2/MARKETING_VERSION: 0.0.3/' "$lurume_work_dir/preflight/project.yml"
print '# Lurume v0.0.3' > "$lurume_work_dir/preflight/release-notes/v0.0.3.md"
git -C "$lurume_work_dir/preflight" add project.yml release-notes/v0.0.3.md
git -C "$lurume_work_dir/preflight" commit -q -m release

"$lurume_work_dir/preflight/Scripts/prepare-release" 0.0.3 3 --preflight-only >/dev/null
expect_failure \
    '准备版本与工程版本不一致' \
    "$lurume_work_dir/preflight/Scripts/prepare-release" 0.0.4 4 --preflight-only

print 'P6 发布脚本输入、哈希与路径边界测试通过。'
