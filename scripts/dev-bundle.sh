#!/usr/bin/env bash
# 本地走查用的 ad-hoc claudi0.app —— release.yml「Assemble claudi0.app」的单架构等价物。
# CI 那份用 lipo 合双架构；走查只需要本机这一个架构。
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
source "$script_dir/pinned-output-directory.sh"
cd "$repo_root"

REQUESTED_VERSION="${CLAUDIO_VERSION:-}"
if [[ -n "$REQUESTED_VERSION" && ! "$REQUESTED_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "❌ CLAUDIO_VERSION must be an unprefixed MAJOR.MINOR.PATCH value" >&2
    exit 2
fi

GUI_NATIVE_HOST_CARD_PROBE=false
ADDITIONAL_HOST_ACCEPTANCE=false
BAILIAN_ACCEPTANCE=false
BAILIAN_BUILD_OPTIONS=()
SWIFT_BUILD_OPTIONS=()
HOST_BUILD_OPTIONS=()
PREVIEW_BUILD_OPTIONS=()
PREVIEW_CHANNEL=development
for option in "$@"; do
    case "$option" in
        --public-preview)
            PREVIEW_CHANNEL=preview
            PREVIEW_BUILD_OPTIONS=(-Xswiftc -DCLAUDIO_PUBLIC_PREVIEW)
            ;;
        --native-host-card-probe) GUI_NATIVE_HOST_CARD_PROBE=true ;;
        --additional-host-acceptance)
            ADDITIONAL_HOST_ACCEPTANCE=true
            HOST_BUILD_OPTIONS=(-Xswiftc -DCLAUDIO_ADDITIONAL_HOST_ACCEPTANCE)
            ;;
        --bailian-acceptance)
            BAILIAN_ACCEPTANCE=true
            BAILIAN_BUILD_OPTIONS=(-Xswiftc -DCLAUDIO_BAILIAN_ACCEPTANCE)
            ;;
        --native-sdk)
            SWIFT_BUILD_OPTIONS=(--build-system native --sdk "$(xcrun --sdk macosx --show-sdk-path)")
            ;;
        *) echo "usage: $0 [--public-preview] [--native-host-card-probe] [--additional-host-acceptance] [--bailian-acceptance] [--native-sdk]" >&2; exit 2 ;;
    esac
done
if [[ "$PREVIEW_CHANNEL" == preview ]]; then
    [[ "$REQUESTED_VERSION" =~ ^0\.0\.[1-9][0-9]*$ ]] || { echo "preview requires CLAUDIO_VERSION=0.0.N" >&2; exit 2; }
    [[ "$BAILIAN_ACCEPTANCE" == false && "$ADDITIONAL_HOST_ACCEPTANCE" == false ]] || exit 2
fi
if [[ -n "${CLAUDIO_BUILD_SDK:-}" ]]; then
    SWIFT_BUILD_OPTIONS=(--build-system native --sdk "$CLAUDIO_BUILD_SDK")
fi

gui_build() {
    # SwiftPM full LTO reduces GUI code size and preserves bundled resources.
    if [[ "$GUI_NATIVE_HOST_CARD_PROBE" == true ]]; then
        swift build -c release --package-path "$repo_root/gui" --product ClaudioGUI \
            --experimental-lto-mode full -Xswiftc -Osize \
            -Xswiftc -DCLAUDIO_NATIVE_HOST_CARD_PROBE \
            "${BAILIAN_BUILD_OPTIONS[@]+"${BAILIAN_BUILD_OPTIONS[@]}"}" \
            "${HOST_BUILD_OPTIONS[@]+"${HOST_BUILD_OPTIONS[@]}"}" \
            "${PREVIEW_BUILD_OPTIONS[@]+"${PREVIEW_BUILD_OPTIONS[@]}"}" \
            "${SWIFT_BUILD_OPTIONS[@]+"${SWIFT_BUILD_OPTIONS[@]}"}" "$@"
    else
        swift build -c release --package-path "$repo_root/gui" --product ClaudioGUI \
            --experimental-lto-mode full -Xswiftc -Osize \
            "${BAILIAN_BUILD_OPTIONS[@]+"${BAILIAN_BUILD_OPTIONS[@]}"}" \
            "${HOST_BUILD_OPTIONS[@]+"${HOST_BUILD_OPTIONS[@]}"}" \
            "${PREVIEW_BUILD_OPTIONS[@]+"${PREVIEW_BUILD_OPTIONS[@]}"}" \
            "${SWIFT_BUILD_OPTIONS[@]+"${SWIFT_BUILD_OPTIONS[@]}"}" "$@"
    fi
}

login_item_build() {
    swift build -c release --package-path "$repo_root/gui" --product ClaudioLoginItem \
        "${SWIFT_BUILD_OPTIONS[@]+"${SWIFT_BUILD_OPTIONS[@]}"}" "$@"
}

find_unique_gui_resource_bundle() {
  local search_dir="$1"
  local -a candidates=()
  shopt -s nullglob
  candidates=("$search_dir"/*_ClaudioGUI.bundle)
  shopt -u nullglob
  if [[ ${#candidates[@]} -ne 1 || ! -d "${candidates[0]:-}" ]]; then
    echo "❌ expected exactly one *_ClaudioGUI.bundle in $search_dir; found ${#candidates[@]}" >&2
    return 1
  fi
  printf '%s\n' "${candidates[0]}"
}

find_unique_localization_bundle() {
  local search_dir="$1"
  local -a candidates=()
  shopt -s nullglob
  candidates=("$search_dir"/*_ClaudioLocalization.bundle)
  shopt -u nullglob
  if [[ ${#candidates[@]} -ne 1 || ! -d "${candidates[0]:-}" ]]; then
    echo "❌ expected exactly one *_ClaudioLocalization.bundle in $search_dir; found ${#candidates[@]}" >&2
    return 1
  fi
  printf '%s\n' "${candidates[0]}"
}

assemble_dev_bundle() (
    local APP="claudi0.app"
    local LEGACY_APP="Claudio.app"
    local BUNDLE_VERSION
    local GUI_BIN_DIR
    local GUI_RESOURCE_BUNDLE
    local HELPER_BINARY
    local HELPER_BIN_DIR
    local LOGIN_ITEM_APP
    local LOGIN_ITEM_BIN_DIR
    local LOGIN_ITEM_BINARY
    local LOCALIZATION_BUNDLE
    local BAILIAN_SOURCE_IDENTITY=""

    verify_bailian_source_identity() {
        if [[ "$BAILIAN_ACCEPTANCE" == true ]]; then
            python3 "$repo_root/scripts/bailian-acceptance-source.py" verify \
                "$repo_root" "$BAILIAN_SOURCE_IDENTITY"
        fi
    }

    # Validate source only after the output directory identity has been pinned.
    python3 "$repo_root/scripts/embed-opencode-plugin.py" --check

    # 建之前先清旧 bundle：若下面任一 `swift build` 因编译错误退出（set -e），旧 app
    # 不能留在原地——否则走查者会 `open` 到上一次成功构建的旧二进制，却以为测的是这次改动。
    rm -rf "$APP" "$LEGACY_APP"

    if [[ "$BAILIAN_ACCEPTANCE" == true ]]; then
        BAILIAN_SOURCE_IDENTITY="$(mktemp "${TMPDIR:-/tmp}/claudio-bailian-source.XXXXXX")"
        # This subshell owns both the frozen manifest and this build's app. Drift or any
        # subsequent build failure must not leave an app claiming the frozen identity.
        trap 'status=$?; rm -f -- "$BAILIAN_SOURCE_IDENTITY" "$BAILIAN_SOURCE_IDENTITY.state"; if [[ $status -ne 0 ]]; then rm -rf -- "$APP"; fi' EXIT
        python3 "$repo_root/scripts/bailian-acceptance-source.py" freeze \
            "$repo_root" "$BAILIAN_SOURCE_IDENTITY"
        verify_bailian_source_identity
    fi

    # 两个 `--product` 都不是可省的修饰：裸 `swift build -c release` 会连各自的测试
    # executable 一起建，而测试会引用 `#if DEBUG` 门控的 fixture，Release 下编译不过。
    gui_build
    verify_bailian_source_identity
    login_item_build
    verify_bailian_source_identity
    # Size optimization keeps the plugin/parser inside the unchanged helper budget.
    swift build -c release --package-path "$repo_root/helper" --product claudio -Xswiftc -Osize \
        "${HOST_BUILD_OPTIONS[@]+"${HOST_BUILD_OPTIONS[@]}"}" \
            "${PREVIEW_BUILD_OPTIONS[@]+"${PREVIEW_BUILD_OPTIONS[@]}"}" \
        "${SWIFT_BUILD_OPTIONS[@]+"${SWIFT_BUILD_OPTIONS[@]}"}"
    verify_bailian_source_identity

    GUI_BIN_DIR="$(gui_build --show-bin-path)"
    GUI_RESOURCE_BUNDLE="$(find_unique_gui_resource_bundle "$GUI_BIN_DIR")"
    LOCALIZATION_BUNDLE="$(find_unique_localization_bundle "$GUI_BIN_DIR")"

    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" \
        "$APP/Contents/Resources/packs"
    cp "$GUI_BIN_DIR/ClaudioGUI" "$APP/Contents/MacOS/claudi0-app"
    cp -R "$GUI_RESOURCE_BUNDLE" "$APP/Contents/Resources/$(basename "$GUI_RESOURCE_BUNDLE")"
    cp -R "$LOCALIZATION_BUNDLE" "$APP/Contents/Resources/$(basename "$LOCALIZATION_BUNDLE")"
    cp -R "$repo_root/gui/AppResources/en.lproj" "$APP/Contents/Resources/en.lproj"
    cp -R "$repo_root/gui/AppResources/zh-Hans.lproj" \
        "$APP/Contents/Resources/zh-Hans.lproj"
    HELPER_BIN_DIR="$(swift build -c release --package-path "$repo_root/helper" \
        --product claudio -Xswiftc -Osize \
        "${HOST_BUILD_OPTIONS[@]+"${HOST_BUILD_OPTIONS[@]}"}" \
            "${PREVIEW_BUILD_OPTIONS[@]+"${PREVIEW_BUILD_OPTIONS[@]}"}" \
        "${SWIFT_BUILD_OPTIONS[@]+"${SWIFT_BUILD_OPTIONS[@]}"}" --show-bin-path)"
    HELPER_BINARY="$HELPER_BIN_DIR/claudio"
    BUNDLE_VERSION="$("$HELPER_BINARY" --version)"
    if [[ "$BUNDLE_VERSION" != "0.0.0-dev" \
        && ! "$BUNDLE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
        echo "❌ helper returned an invalid embedded version: $BUNDLE_VERSION" >&2
        return 1
    fi
    if [[ -n "$REQUESTED_VERSION" && "$BUNDLE_VERSION" != "$REQUESTED_VERSION" ]]; then
        echo "❌ helper version mismatch: requested=$REQUESTED_VERSION embedded=$BUNDLE_VERSION" >&2
        return 1
    fi
    cp "$HELPER_BINARY" "$APP/Contents/Resources/bin/claudi0"
    # 旧入口继续可执行，但只保留一个 helper Mach-O；相对链接在 app/DMG 搬动后仍然成立。
    ln -s claudi0 "$APP/Contents/Resources/bin/claudio"
    bash "$repo_root/scripts/copy-bundled-packs.sh" "$repo_root/packs" \
        "$APP/Contents/Resources/packs"
    cp "$repo_root/LICENSE" "$APP/Contents/Resources/LICENSE"
    cp "$repo_root/PRIVACY.md" "$APP/Contents/Resources/PRIVACY.md"
    mkdir -p "$APP/Contents/Resources/integrations/opencode"
    cp "$repo_root/integrations/opencode/claudio.js" "$APP/Contents/Resources/integrations/opencode/claudio.js"
    cp "$repo_root/assets/branding/claudi0.icns" "$APP/Contents/Resources/claudi0.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>claudi0</string>
  <key>CFBundleDisplayName</key><string>claudi0</string>
  <key>ClaudioBrandName</key><string>Orbit Zero</string>
  <key>CFBundleIdentifier</key><string>com.claudio.app</string>
  <key>CFBundleVersion</key><string>$BUNDLE_VERSION</string>
  <key>CFBundleShortVersionString</key><string>$BUNDLE_VERSION</string>
  <key>CFBundleExecutable</key><string>claudi0-app</string>
  <key>CFBundleIconFile</key><string>claudi0.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSAppleEventsUsageDescription</key><string>claudi0 uses terminal automation only when you choose to return to an event session.</string>
  <key>NSFocusStatusUsageDescription</key><string>claudi0 uses only whether Focus is active to temporarily quiet automatic sounds. It never stores the Focus name.</string>
  <key>NSCalendarsUsageDescription</key><string>claudi0 checks only whether a non-all-day busy event is active to temporarily quiet automatic sounds. It never stores event details.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>claudi0 checks only whether a non-all-day busy event is active to temporarily quiet automatic sounds. It never stores event details.</string>
  <key>LSUIElement</key><true/>
  <key>UTExportedTypeDeclarations</key>
  <array><dict>
    <key>UTTypeIdentifier</key><string>com.claudio.sound-pack</string>
    <key>UTTypeDescription</key><string>Claudio Sound Pack</string>
    <key>UTTypeConformsTo</key><array><string>com.apple.package</string><string>public.directory</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>claudiopack</string></array></dict>
  </dict></array>
</dict>
</plist>
PLIST
    printf 'APPL????' > "$APP/Contents/PkgInfo"
    if [[ "$BAILIAN_ACCEPTANCE" == true ]]; then
        /usr/libexec/PlistBuddy -c 'Add :ClaudioBailianAcceptance bool true' "$APP/Contents/Info.plist"
        verify_bailian_source_identity
        cp "$BAILIAN_SOURCE_IDENTITY" "$APP/Contents/Resources/bailian-acceptance-source.json"
    fi
    if [[ "$ADDITIONAL_HOST_ACCEPTANCE" == true ]]; then
        /usr/libexec/PlistBuddy -c 'Add :ClaudioAdditionalHostAcceptance bool true' "$APP/Contents/Info.plist"
    fi

    python3 "$repo_root/scripts/sparkle-bundle.py" embed "$APP" --source \
        "$repo_root/gui/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    python3 "$repo_root/scripts/sparkle-bundle.py" configure "$APP" --channel "$PREVIEW_CHANNEL"

    LOGIN_ITEM_BIN_DIR="$(login_item_build --show-bin-path)"
    LOGIN_ITEM_BINARY="$LOGIN_ITEM_BIN_DIR/ClaudioLoginItem"
    bash "$repo_root/scripts/assemble-login-item.sh" \
        "$LOGIN_ITEM_BINARY" "$APP" "$BUNDLE_VERSION"
    LOGIN_ITEM_APP="$APP/Contents/Library/LoginItems/claudi0 LoginItem.app"

    # The SwiftUI executable exports a large Swift symbol table that the app never loads by name.
    # Strip it completely before the size gate; helper/LoginItem keep their existing external
    # symbols because they are separate release contracts with their own budgets.
    strip "$APP/Contents/MacOS/claudi0-app"
    # strip can leave the linker's temporary signature sized for the unstripped executable.
    # Measure the stripped payload without that obsolete blob, then check the final signed app.
    if codesign --display "$APP/Contents/MacOS/claudi0-app" >/dev/null 2>&1; then
        codesign --remove-signature "$APP/Contents/MacOS/claudi0-app"
    fi
    strip -x \
        "$APP/Contents/Resources/bin/claudi0" \
        "$LOGIN_ITEM_APP/Contents/MacOS/claudi0-login-item"
    bash "$repo_root/scripts/check-release-size.sh" "$APP"

    verify_bailian_source_identity
    codesign --force --sign - "$APP/Contents/Resources/bin/claudi0"
    codesign --force --sign - "$LOGIN_ITEM_APP"
    python3 "$repo_root/scripts/sparkle-bundle.py" sign "$APP"
    codesign --force --sign - "$APP"
    bash "$repo_root/scripts/verify-dev-bundle-signature.sh" "$APP"
    python3 "$repo_root/scripts/sparkle-bundle.py" verify "$APP" --archs "$(uname -m)"
    bash "$repo_root/scripts/check-release-size.sh" "$APP"
    verify_bailian_source_identity
    echo "✅ dist/${APP}（$(uname -m)）—— 用 open dist/${APP} 启动（菜单栏出现 Orbit Zero 图标）"
)

claudio_with_pinned_output_directory "$repo_root" "dist" assemble_dev_bundle
