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

lurume_main_refspec() {
    local lurume_sha="$1"
    [[ "$lurume_sha" =~ '^[0-9a-f]{40}$' ]] || {
        lurume_release_error "Git SHA 必须是 40 位小写十六进制：$lurume_sha"
        return 1
    }
    print -r -- "${lurume_sha}:refs/heads/main"
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
    jq -er "$lurume_filter" "$lurume_manifest"
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

lurume_verify_translation_xpc_entitlements() {
    local lurume_entitlements="$1"

    [[ "$lurume_entitlements" == *'com.apple.security.app-sandbox'* ]] || {
        lurume_release_error 'Translation XPC 缺少 App Sandbox entitlement'
        return 1
    }
    [[ "$lurume_entitlements" == *'com.apple.security.network.client'* ]] || {
        lurume_release_error 'Translation XPC 缺少 network client entitlement'
        return 1
    }

    local lurume_forbidden
    for lurume_forbidden in \
        'com.apple.security.network.server' \
        'com.apple.security.files.' \
        'com.apple.security.temporary-exception.mach-lookup' \
        'com.apple.security.personal-information.' \
        'com.apple.security.assets.' \
        'com.apple.security.device.' \
        'keychain-access-groups' \
        'com.apple.security.get-task-allow'; do
        [[ "$lurume_entitlements" != *"$lurume_forbidden"* ]] || {
            lurume_release_error "Translation XPC 包含禁止的 entitlement：$lurume_forbidden"
            return 1
        }
    done
}

lurume_verify_translation_fixture_text() {
    local lurume_text="$1"
    local lurume_marker
    for lurume_marker in \
        'fixture selection only' \
        'connection ok' \
        'test-placeholder-key' \
        '127.0.0.1:8765'; do
        [[ "$lurume_text" != *"$lurume_marker"* ]] || {
            lurume_release_error "Release 包含 P7 测试夹具文本：$lurume_marker"
            return 1
        }
    done
}

lurume_verify_translation_xpc() {
    local lurume_app="$1"
    local lurume_xpc="$lurume_app/Contents/XPCServices/LurumeTranslationService.xpc"
    local lurume_binary="$lurume_xpc/Contents/MacOS/LurumeTranslationService"
    local lurume_info="$lurume_xpc/Contents/Info.plist"

    [[ -d "$lurume_xpc" && ! -L "$lurume_xpc" ]] || {
        lurume_release_error 'Release App 缺少内嵌 Translation XPC'
        return 1
    }
    [[ -x "$lurume_binary" && -f "$lurume_info" ]] || {
        lurume_release_error 'Translation XPC 结构不完整'
        return 1
    }
    [[ "$(find "$lurume_app/Contents/XPCServices" -maxdepth 1 -type d -name 'LurumeTranslationService.xpc' | wc -l | tr -d ' ')" == '1' ]] || {
        lurume_release_error 'Translation XPC 数量不唯一'
        return 1
    }

    codesign --verify --strict --verbose=2 "$lurume_xpc" >/dev/null || {
        lurume_release_error 'Translation XPC 严格签名校验失败'
        return 1
    }
    local lurume_archs
    lurume_archs="$(lipo -archs "$lurume_binary")"
    [[ "$lurume_archs" == *arm64* && "$lurume_archs" == *x86_64* ]] || {
        lurume_release_error "Translation XPC 不是 Universal：$lurume_archs"
        return 1
    }
    [[ "$(plutil -extract CFBundleIdentifier raw "$lurume_info")" == 'app.lurume.Lurume.TranslationService' ]] || {
        lurume_release_error 'Translation XPC Bundle ID 不一致'
        return 1
    }
    [[ "$(plutil -extract CFBundlePackageType raw "$lurume_info")" == 'XPC!' ]] || {
        lurume_release_error 'Translation XPC 包类型不一致'
        return 1
    }
    [[ "$(plutil -extract LSMinimumSystemVersion raw "$lurume_info")" == '15.0' ]] || {
        lurume_release_error 'Translation XPC 最低系统版本不是 15.0'
        return 1
    }

    local lurume_entitlements
    lurume_entitlements="$(codesign -d --entitlements - "$lurume_xpc" 2>&1)" || {
        lurume_release_error '无法读取 Translation XPC entitlement'
        return 1
    }
    lurume_verify_translation_xpc_entitlements "$lurume_entitlements" || return 1

    local lurume_release_strings
    lurume_release_strings="$(strings "$lurume_app/Contents/MacOS/Lurume")
$(strings "$lurume_binary")"
    lurume_verify_translation_fixture_text "$lurume_release_strings"
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
