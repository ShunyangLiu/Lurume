#!/bin/zsh

set -euo pipefail
setopt NULL_GLOB

lurume_script_dir="${0:A:h}"
lurume_fixture_dir="$lurume_script_dir/Fixtures"
lurume_sparkle_bin_dir="${SPARKLE_BIN_DIR:-}"
lurume_account="${LURUME_SPARKLE_ACCOUNT:-ShunyangLiu}"
lurume_private_key_file="${LURUME_SPARKLE_PRIVATE_KEY_FILE:-}"

if [[ -z "$lurume_sparkle_bin_dir" ]]; then
    lurume_candidates=(
        "${HOME}/Library/Developer/Xcode/DerivedData"/Lurume-*/SourcePackages/artifacts/sparkle/Sparkle/bin
    )
    for lurume_candidate in "${lurume_candidates[@]}"; do
        if [[ -x "$lurume_candidate/sign_update" ]]; then
            lurume_sparkle_bin_dir="$lurume_candidate"
            break
        fi
    done
fi

lurume_sign_tool="$lurume_sparkle_bin_dir/sign_update"
if [[ ! -x "$lurume_sign_tool" ]]; then
    print -u2 "找不到固定 Sparkle 的 sign_update；请设置 SPARKLE_BIN_DIR。"
    exit 2
fi

lurume_signing_args=()
if [[ -n "$lurume_private_key_file" ]]; then
    if [[ ! -f "$lurume_private_key_file" ]]; then
        print -u2 "指定的私钥备份文件不存在。"
        exit 3
    fi
    lurume_signing_args=(--ed-key-file "$lurume_private_key_file")
else
    lurume_signing_args=(--account "$lurume_account")
fi

lurume_tmp_base="${TMPDIR:-/tmp}"
lurume_work_dir="$(mktemp -d "$lurume_tmp_base/lurume-p6-signing.XXXXXX")"
cleanup_lurume_signing_matrix() {
    case "$lurume_work_dir" in
        "$lurume_tmp_base"/lurume-p6-signing.*)
            rm -rf -- "$lurume_work_dir"
            ;;
        *)
            print -u2 "拒绝清理意外的临时目录：$lurume_work_dir"
            ;;
    esac
}
trap cleanup_lurume_signing_matrix EXIT INT TERM

cp "$lurume_fixture_dir/sample-update.dmg" "$lurume_work_dir/sample-update.dmg"
cp "$lurume_fixture_dir/sample-release-notes.html" "$lurume_work_dir/sample-release-notes.html"

lurume_archive_attributes="$($lurume_sign_tool "${lurume_signing_args[@]}" "$lurume_work_dir/sample-update.dmg")"
lurume_archive_signature="$(print -r -- "$lurume_archive_attributes" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
lurume_archive_length="$(stat -f '%z' "$lurume_work_dir/sample-update.dmg")"

lurume_notes_attributes="$($lurume_sign_tool "${lurume_signing_args[@]}" --disable-signing-warning "$lurume_work_dir/sample-release-notes.html")"
lurume_notes_signature="$(print -r -- "$lurume_notes_attributes" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
lurume_notes_length="$(stat -f '%z' "$lurume_work_dir/sample-release-notes.html")"

if [[ -z "$lurume_archive_signature" || -z "$lurume_notes_signature" ]]; then
    print -u2 "Sparkle 未返回预期的 EdDSA 签名属性。"
    exit 4
fi

sed \
    -e "s|__ARCHIVE_SIGNATURE__|$lurume_archive_signature|g" \
    -e "s|__ARCHIVE_LENGTH__|$lurume_archive_length|g" \
    -e "s|__NOTES_SIGNATURE__|$lurume_notes_signature|g" \
    -e "s|__NOTES_LENGTH__|$lurume_notes_length|g" \
    "$lurume_fixture_dir/unsigned-appcast.xml" > "$lurume_work_dir/appcast.xml"

$lurume_sign_tool "${lurume_signing_args[@]}" --disable-signing-warning "$lurume_work_dir/appcast.xml" >/dev/null

$lurume_sign_tool "${lurume_signing_args[@]}" --verify "$lurume_work_dir/sample-update.dmg" "$lurume_archive_signature" >/dev/null
$lurume_sign_tool "${lurume_signing_args[@]}" --verify "$lurume_work_dir/sample-release-notes.html" "$lurume_notes_signature" >/dev/null
$lurume_sign_tool "${lurume_signing_args[@]}" --verify "$lurume_work_dir/appcast.xml" >/dev/null

expect_lurume_rejection() {
    local lurume_case_name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        print -u2 "应拒绝但通过：$lurume_case_name"
        exit 5
    fi
    print "已拒绝：$lurume_case_name"
}

cp "$lurume_work_dir/sample-update.dmg" "$lurume_work_dir/tampered-update.dmg"
print '\nmodified archive byte' >> "$lurume_work_dir/tampered-update.dmg"
expect_lurume_rejection \
    "被修改的更新归档" \
    "$lurume_sign_tool" "${lurume_signing_args[@]}" --verify \
    "$lurume_work_dir/tampered-update.dmg" "$lurume_archive_signature"

cp "$lurume_work_dir/sample-release-notes.html" "$lurume_work_dir/tampered-release-notes.html"
print '\n<!-- modified release notes -->' >> "$lurume_work_dir/tampered-release-notes.html"
expect_lurume_rejection \
    "被修改的外部更新说明" \
    "$lurume_sign_tool" "${lurume_signing_args[@]}" --verify \
    "$lurume_work_dir/tampered-release-notes.html" "$lurume_notes_signature"

cp "$lurume_work_dir/appcast.xml" "$lurume_work_dir/tampered-appcast.xml"
sed -i '' 's|<sparkle:version>9001</sparkle:version>|<sparkle:version>9002</sparkle:version>|' \
    "$lurume_work_dir/tampered-appcast.xml"
expect_lurume_rejection \
    "签名 appcast 中被修改的版本" \
    "$lurume_sign_tool" "${lurume_signing_args[@]}" --verify \
    "$lurume_work_dir/tampered-appcast.xml"

cp "$lurume_work_dir/appcast.xml" "$lurume_work_dir/tampered-url-appcast.xml"
sed -i '' 's|sample-update.dmg|missing-update.dmg|' \
    "$lurume_work_dir/tampered-url-appcast.xml"
expect_lurume_rejection \
    "签名 appcast 中被修改的下载地址" \
    "$lurume_sign_tool" "${lurume_signing_args[@]}" --verify \
    "$lurume_work_dir/tampered-url-appcast.xml"

lurume_wrong_archive_length="$((lurume_archive_length + 1))"
cp "$lurume_work_dir/appcast.xml" "$lurume_work_dir/tampered-length-appcast.xml"
sed -i '' "s|length=\"$lurume_archive_length\"|length=\"$lurume_wrong_archive_length\"|" \
    "$lurume_work_dir/tampered-length-appcast.xml"
expect_lurume_rejection \
    "签名 appcast 中被修改的归档长度" \
    "$lurume_sign_tool" "${lurume_signing_args[@]}" --verify \
    "$lurume_work_dir/tampered-length-appcast.xml"

print '有效签名：更新归档、外部更新说明、appcast'
print '篡改拒绝：5 / 5'
