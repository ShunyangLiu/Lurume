#!/bin/zsh

# Shared, non-mutating validation helpers for Lurume's local release tools.

lurume_release_error() {
    print -u2 -- "错误：$*"
    return 1
}

lurume_require_semver() {
    local lurume_version="$1"
    [[ "$lurume_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || \
        lurume_release_error "版本号必须是 x.y.z：$lurume_version"
}

lurume_require_build_number() {
    local lurume_build="$1"
    [[ "$lurume_build" =~ '^[1-9][0-9]*$' ]] || \
        lurume_release_error "构建号必须是正整数：$lurume_build"
}

lurume_sha256() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print $1 }'
}

lurume_file_size() {
    /usr/bin/stat -f '%z' "$1"
}

lurume_manifest_value() {
    local lurume_manifest="$1"
    local lurume_filter="$2"
    /usr/bin/jq -er "$lurume_filter" "$lurume_manifest"
}

lurume_safe_relative_path() {
    local lurume_path="$1"
    [[ -n "$lurume_path" ]] || return 1
    [[ "$lurume_path" != /* ]] || return 1
    [[ "/$lurume_path/" != *'/../'* ]] || return 1
    [[ "$lurume_path" != '..' ]] || return 1
}

lurume_verify_manifest_files() {
    local lurume_artifact_dir="$1"
    local lurume_manifest="$lurume_artifact_dir/manifest.json"
    local lurume_kind lurume_path lurume_expected_hash lurume_expected_size
    local lurume_actual_hash lurume_actual_size

    [[ -f "$lurume_manifest" && ! -L "$lurume_manifest" ]] || {
        lurume_release_error "缺少发布清单：$lurume_manifest"
        return 1
    }

    [[ "$(lurume_manifest_value "$lurume_manifest" '.schema_version')" == '1' ]] || {
        lurume_release_error "不支持的发布清单版本"
        return 1
    }

    for lurume_kind in dmg appcast release_notes; do
        lurume_path="$(lurume_manifest_value "$lurume_manifest" ".files.${lurume_kind}.path")" || return 1
        lurume_safe_relative_path "$lurume_path" || {
            lurume_release_error "清单包含不安全路径：$lurume_path"
            return 1
        }

        local lurume_file="$lurume_artifact_dir/$lurume_path"
        [[ -f "$lurume_file" && ! -L "$lurume_file" ]] || {
            lurume_release_error "清单文件不存在：$lurume_path"
            return 1
        }

        lurume_expected_hash="$(lurume_manifest_value "$lurume_manifest" ".files.${lurume_kind}.sha256")" || return 1
        lurume_expected_size="$(lurume_manifest_value "$lurume_manifest" ".files.${lurume_kind}.length")" || return 1
        lurume_actual_hash="$(lurume_sha256 "$lurume_file")"
        lurume_actual_size="$(lurume_file_size "$lurume_file")"

        [[ "$lurume_actual_hash" == "$lurume_expected_hash" ]] || {
            lurume_release_error "文件哈希与清单不符：$lurume_path"
            return 1
        }
        [[ "$lurume_actual_size" == "$lurume_expected_size" ]] || {
            lurume_release_error "文件长度与清单不符：$lurume_path"
            return 1
        }
    done
}

lurume_xml_string() {
    local lurume_file="$1"
    local lurume_xpath="$2"
    /usr/bin/xmllint --xpath "string($lurume_xpath)" "$lurume_file" 2>/dev/null
}

lurume_verify_release_notes_heading() {
    local lurume_notes="$1"
    local lurume_version="$2"
    local lurume_heading
    lurume_heading="$(/usr/bin/sed -n '1p' "$lurume_notes")"
    [[ "$lurume_heading" == "# Lurume v$lurume_version" ]] || \
        lurume_release_error "更新说明首行必须是：# Lurume v$lurume_version"
}

lurume_find_sparkle_tool() {
    local lurume_derived_data="$1"
    local lurume_tool_name="$2"
    local lurume_candidate

    lurume_candidate="$lurume_derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin/$lurume_tool_name"
    [[ -x "$lurume_candidate" ]] || {
        lurume_release_error "找不到固定 Sparkle 工具：$lurume_tool_name"
        return 1
    }
    print -r -- "$lurume_candidate"
}

lurume_verify_appcast() {
    local lurume_artifact_dir="$1"
    local lurume_account="$2"
    local lurume_sign_tool="$3"
    local lurume_manifest="$lurume_artifact_dir/manifest.json"
    local lurume_appcast="$lurume_artifact_dir/$(lurume_manifest_value "$lurume_manifest" '.files.appcast.path')"
    local lurume_dmg="$lurume_artifact_dir/$(lurume_manifest_value "$lurume_manifest" '.files.dmg.path')"
    local lurume_notes="$lurume_artifact_dir/$(lurume_manifest_value "$lurume_manifest" '.files.release_notes.path')"
    local lurume_version lurume_build lurume_dmg_url lurume_notes_url
    local lurume_feed_version lurume_feed_short_version lurume_feed_minimum_os
    local lurume_feed_dmg_url lurume_feed_notes_url lurume_feed_dmg_length
    local lurume_archive_signature lurume_notes_signature lurume_delta_count

    lurume_version="$(lurume_manifest_value "$lurume_manifest" '.version')"
    lurume_build="$(lurume_manifest_value "$lurume_manifest" '.build | tostring')"
    lurume_dmg_url="$(lurume_manifest_value "$lurume_manifest" '.download_url')"
    lurume_notes_url="$(lurume_manifest_value "$lurume_manifest" '.release_notes_url')"

    lurume_feed_version="$(lurume_xml_string "$lurume_appcast" '(//*[local-name()="item"])[1]/*[local-name()="version"]')"
    lurume_feed_short_version="$(lurume_xml_string "$lurume_appcast" '(//*[local-name()="item"])[1]/*[local-name()="shortVersionString"]')"
    lurume_feed_minimum_os="$(lurume_xml_string "$lurume_appcast" '(//*[local-name()="item"])[1]/*[local-name()="minimumSystemVersion"]')"
    lurume_feed_dmg_url="$(lurume_xml_string "$lurume_appcast" '(//*[local-name()="item"])[1]/*[local-name()="enclosure"]/@url')"
    lurume_feed_notes_url="$(lurume_xml_string "$lurume_appcast" '(//*[local-name()="item"])[1]/*[local-name()="releaseNotesLink"]')"
    lurume_feed_dmg_length="$(lurume_xml_string "$lurume_appcast" '(//*[local-name()="item"])[1]/*[local-name()="enclosure"]/@length')"
    lurume_archive_signature="$(lurume_xml_string "$lurume_appcast" '(//*[local-name()="item"])[1]/*[local-name()="enclosure"]/@*[local-name()="edSignature"]')"
    lurume_notes_signature="$(lurume_xml_string "$lurume_appcast" '(//*[local-name()="item"])[1]/*[local-name()="releaseNotesLink"]/@*[local-name()="edSignature"]')"
    lurume_delta_count="$(/usr/bin/xmllint --xpath 'count(//*[local-name()="deltas"]/*)' "$lurume_appcast" 2>/dev/null)"

    [[ "$lurume_feed_version" == "$lurume_build" ]] || lurume_release_error "appcast 构建号不一致" || return 1
    [[ "$lurume_feed_short_version" == "$lurume_version" ]] || lurume_release_error "appcast 展示版本不一致" || return 1
    [[ "$lurume_feed_minimum_os" == '15.0' ]] || lurume_release_error "appcast 最低系统版本不是 15.0" || return 1
    [[ "$lurume_feed_dmg_url" == "$lurume_dmg_url" ]] || lurume_release_error "appcast 下载地址不一致" || return 1
    [[ "$lurume_feed_notes_url" == "$lurume_notes_url" ]] || lurume_release_error "appcast 更新说明地址不一致" || return 1
    [[ "$lurume_feed_dmg_length" == "$(lurume_file_size "$lurume_dmg")" ]] || lurume_release_error "appcast 归档长度不一致" || return 1
    [[ "$lurume_delta_count" == '0' ]] || lurume_release_error "第一版 appcast 不得包含 delta" || return 1
    [[ -n "$lurume_archive_signature" && -n "$lurume_notes_signature" ]] || lurume_release_error "appcast 缺少 EdDSA 文件签名" || return 1

    "$lurume_sign_tool" --account "$lurume_account" --verify "$lurume_dmg" "$lurume_archive_signature" >/dev/null
    "$lurume_sign_tool" --account "$lurume_account" --verify "$lurume_notes" "$lurume_notes_signature" >/dev/null
    "$lurume_sign_tool" --account "$lurume_account" --verify "$lurume_appcast" >/dev/null
}
