#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
APP_VERSION="2.0.0"
APP_BUILD="16"
BUNDLE_IDENTIFIER="local.novelreader.app"
EXECUTABLE_NAME="MyEditor"
PROCESS_PATTERN="NovelReader|MyEditor"
DEBUG_PRODUCT="debug"
CONFIGURATION=debug
LAUNCH=1
VERIFY=0
LOGS=0
DEBUGGER=0
APP_ALREADY_CLOSED=0
METRICS=0
EDITOR_CHECKS=0
DROP_CHECKS=0
FEATURE_CHECKS=0
FEATURE_PHASE=all
for OPTION in "$@"; do
    case "$OPTION" in
        --release) CONFIGURATION=release ;;
        --build-only) LAUNCH=0 ;;
        --verify) VERIFY=1 ;;
        --logs|--telemetry) LOGS=1 ;;
        --debug) DEBUGGER=1 ;;
        --nested-sandbox) export NOVELREADER_NESTED_SANDBOX=1 ;;
        --app-already-closed) APP_ALREADY_CLOSED=1 ;;
        --metrics) METRICS=1 ;;
        --editor-checks) EDITOR_CHECKS=1; METRICS=1 ;;
        --drop-checks) DROP_CHECKS=1; METRICS=1 ;;
        --feature-checks) FEATURE_CHECKS=1; METRICS=1 ;;
        --feature-checks=*) FEATURE_CHECKS=1; METRICS=1; FEATURE_PHASE="${OPTION#*=}" ;;
        *) echo "Unknown option: $OPTION" >&2; exit 2 ;;
    esac
done
if [[ ( "$EDITOR_CHECKS" == "1" || "$DROP_CHECKS" == "1" || "$FEATURE_CHECKS" == "1" ) && "$CONFIGURATION" == "release" ]]; then
    echo "Native integration checks run in debug builds. Omit --release." >&2
    exit 2
fi

if (( EDITOR_CHECKS + DROP_CHECKS + FEATURE_CHECKS > 1 )); then
    echo "Run one native integration check mode at a time." >&2
    exit 2
fi

# Automated GUI checks own a separate identity and process. They must not close
# user windows or share normal application preferences/recent-document state.
if (( EDITOR_CHECKS + DROP_CHECKS + FEATURE_CHECKS > 0 )); then
    BUNDLE_IDENTIFIER="local.myeditor.validation"
    EXECUTABLE_NAME="MyEditorValidation"
    PROCESS_PATTERN="MyEditorValidation"
    DEBUG_PRODUCT="validation"
fi

PROCESS_STATUS=1
if [[ "$APP_ALREADY_CLOSED" == "0" && "$LAUNCH" == "1" ]]; then
    /usr/bin/pgrep -x "$PROCESS_PATTERN" >/dev/null 2>&1 && PROCESS_STATUS=0 || PROCESS_STATUS=$?
fi
if [[ "$PROCESS_STATUS" -gt 1 ]]; then
    echo "This host cannot inspect running processes. Close MyEditor / NovelReader through its UI, verify it exited, then use --app-already-closed." >&2
    exit 1
fi
if [[ "$PROCESS_STATUS" == "0" ]]; then
    echo "Requesting normal quit; the app will save its open documents…"
    if ! /usr/bin/osascript -e "tell application id \"$BUNDLE_IDENTIFIER\" to quit"; then
        echo "Quit was cancelled or could not finish. Build stopped." >&2
        exit 1
    fi
    for ATTEMPT in {1..100}; do
        if ! /usr/bin/pgrep -x "$PROCESS_PATTERN" >/dev/null; then break; fi
        /bin/sleep 0.1
    done
    if /usr/bin/pgrep -x "$PROCESS_PATTERN" >/dev/null; then
        echo "The existing app is still open. Build stopped to preserve its documents." >&2
        exit 1
    fi
fi

export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
if ! command -v npm >/dev/null; then
    echo "Building the local editor requires Node.js/npm; the delivered app does not." >&2
    exit 1
fi
if ! GIT_COMMIT="$(/usr/bin/git rev-parse --verify HEAD 2>/dev/null)"; then
    GIT_COMMIT="uncommitted"
fi
GIT_DIRTY=false
if [[ -n "$(/usr/bin/git status --porcelain --untracked-files=normal)" ]]; then GIT_DIRTY=true; fi
if [[ "$GIT_COMMIT" == "uncommitted" ]]; then
    GIT_SHORT_COMMIT="uncommitted"
else
    GIT_SHORT_COMMIT="${GIT_COMMIT:0:12}"
fi
DIRTY_SUFFIX=""
if [[ "$GIT_DIRTY" == "true" ]]; then DIRTY_SUFFIX="-dirty"; fi
BUILD_TIMESTAMP="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
BUILD_IDENTIFIER="${APP_VERSION}.${APP_BUILD}-${GIT_SHORT_COMMIT}${DIRTY_SUFFIX}-${BUILD_TIMESTAMP}"
SOURCE_FINGERPRINT="$(node "$PROJECT_ROOT/script/release/generate_release_manifest.mjs" --source-fingerprint "$PROJECT_ROOT")"
(
    cd EditorWeb
    DEPENDENCY_HASH="$(/usr/bin/shasum -a 256 package-lock.json)"
    if [[ ! -d node_modules || ! -f ../.cache/editor-dependencies.sha256 || "$(cat ../.cache/editor-dependencies.sha256)" != "$DEPENDENCY_HASH" ]]; then
        npm ci --prefer-offline --no-audit --no-fund
        mkdir -p ../.cache
        printf '%s\n' "$DEPENDENCY_HASH" > ../.cache/editor-dependencies.sha256
    fi
    npm run build
)
./script/swiftpm.sh build --configuration "$CONFIGURATION" --arch arm64 --product MyEditor
BINARY_DIRECTORY="$(./script/swiftpm.sh build --configuration "$CONFIGURATION" --arch arm64 --show-bin-path)"
PRODUCT_ROOT="$PROJECT_ROOT/.cache/products"
STAGING_ROOT="$PRODUCT_ROOT/staging/$BUILD_IDENTIFIER"
STAGING="$STAGING_ROOT/MyEditor.app"
BUNDLE="$PROJECT_ROOT/dist/MyEditor.app"
DSYM_STAGING_ROOT="$PRODUCT_ROOT/symbols/$BUILD_IDENTIFIER"
DSYM_STAGING="$DSYM_STAGING_ROOT/MyEditor.dSYM"
DSYM_ARCHIVE_STAGING="$STAGING_ROOT/MyEditor.dSYM.zip"
RELEASE_MANIFEST="$STAGING_ROOT/MyEditor.release-manifest.json"
mkdir -p "$STAGING_ROOT"
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"
cp "$BINARY_DIRECTORY/MyEditor" "$STAGING/Contents/MacOS/$EXECUTABLE_NAME"
if [[ "$CONFIGURATION" == "release" ]]; then
    # Preserve full symbols outside the app before removing local symbols from the deliverable.
    /bin/rm -rf "$DSYM_STAGING_ROOT"
    /bin/rm -f "$DSYM_ARCHIVE_STAGING"
    mkdir -p "$DSYM_STAGING_ROOT"
    /usr/bin/dsymutil "$STAGING/Contents/MacOS/MyEditor" -o "$DSYM_STAGING"
    /usr/bin/strip -x "$STAGING/Contents/MacOS/MyEditor"
    BINARY_UUID="$(/usr/bin/dwarfdump --uuid "$STAGING/Contents/MacOS/MyEditor" | /usr/bin/awk 'NR == 1 { print $2 }')"
    DSYM_UUID="$(/usr/bin/dwarfdump --uuid "$DSYM_STAGING" | /usr/bin/awk 'NR == 1 { print $2 }')"
    if [[ -z "$BINARY_UUID" || "$BINARY_UUID" != "$DSYM_UUID" ]]; then
        echo "The release binary and dSYM UUIDs do not match." >&2
        exit 1
    fi
    /usr/bin/ditto --norsrc --noextattr --noacl -c -k --keepParent "$DSYM_STAGING" "$DSYM_ARCHIVE_STAGING"
    /bin/rm -rf "$DSYM_STAGING_ROOT"
fi
cp -R "$PROJECT_ROOT/EditorWeb/dist" "$STAGING/Contents/Resources/EditorWeb"
ICON_SOURCE="$PROJECT_ROOT/Resources/MyEditor.svg"
ICON_SCRIPT="$PROJECT_ROOT/script/MakeIcon.swift"
ICON_FINGERPRINT="$(/usr/bin/shasum -a 256 "$ICON_SOURCE" "$ICON_SCRIPT")"
if [[ ! -f "$PROJECT_ROOT/.cache/MyEditor.icns" || ! -f "$PROJECT_ROOT/.cache/MyEditor-icon.sha256" || "$(cat "$PROJECT_ROOT/.cache/MyEditor-icon.sha256")" != "$ICON_FINGERPRINT" ]]; then
    /usr/bin/swift -module-cache-path "$PROJECT_ROOT/.cache/modules" "$ICON_SCRIPT" "$ICON_SOURCE" "$PROJECT_ROOT/.cache/MyEditor.iconset" "$PROJECT_ROOT/.cache/MyEditor.icns"
    printf '%s\n' "$ICON_FINGERPRINT" > "$PROJECT_ROOT/.cache/MyEditor-icon.sha256"
fi
cp "$PROJECT_ROOT/.cache/MyEditor.icns" "$STAGING/Contents/Resources/MyEditor.icns"
cp "$ICON_SOURCE" "$STAGING/Contents/Resources/MyEditor.svg"
cat > "$STAGING/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>${EXECUTABLE_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_IDENTIFIER}</string>
    <key>CFBundleName</key><string>MyEditor</string>
    <key>CFBundleDisplayName</key><string>MyEditor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>MyEditor</string>
    <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
    <key>CFBundleVersion</key><string>${APP_BUILD}</string>
    <key>MyEditorBuildIdentifier</key><string>${BUILD_IDENTIFIER}</string>
    <key>MyEditorBuildConfiguration</key><string>${CONFIGURATION}</string>
    <key>MyEditorGitCommit</key><string>${GIT_COMMIT}</string>
    <key>MyEditorGitDirty</key><${GIT_DIRTY}/>
    <key>MyEditorSourceFingerprint</key><string>${SOURCE_FINGERPRINT}</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleLocalizations</key><array><string>zh_CN</string><string>en</string></array>
    <key>CFBundleDocumentTypes</key><array><dict>
        <key>CFBundleTypeName</key><string>Markdown 文档</string>
        <key>CFBundleTypeRole</key><string>Editor</string>
        <key>LSHandlerRank</key><string>Alternate</string>
        <key>LSItemContentTypes</key><array><string>net.daringfireball.markdown</string></array>
        <key>CFBundleTypeExtensions</key><array><string>md</string></array>
    </dict></array>
    <key>UTImportedTypeDeclarations</key><array><dict>
        <key>UTTypeIdentifier</key><string>net.daringfireball.markdown</string>
        <key>UTTypeDescription</key><string>Markdown</string>
        <key>UTTypeConformsTo</key><array><string>public.plain-text</string></array>
        <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>md</string></array></dict>
    </dict></array>
</dict></plist>
PLIST
if [[ "$METRICS" == "1" ]]; then
    VALIDATION_DIRECTORY="$PROJECT_ROOT/.cache/validation/$BUILD_IDENTIFIER/$(/usr/bin/uuidgen)"
    mkdir -p "$VALIDATION_DIRECTORY"
    printf '%s\n' "$VALIDATION_DIRECTORY" > "$PROJECT_ROOT/.cache/last-validation-directory"
    node "$PROJECT_ROOT/Fixtures/large-manuscript.mjs" "$VALIDATION_DIRECTORY/large-manuscript.md"
    /usr/libexec/PlistBuddy -c "Add :NRDiagnosticsDirectory string $VALIDATION_DIRECTORY" "$STAGING/Contents/Info.plist"
fi
if (( EDITOR_CHECKS + DROP_CHECKS + FEATURE_CHECKS > 0 )); then
    mkdir -p "$STAGING/Contents/Resources/Validation"
    cp "$VALIDATION_DIRECTORY/large-manuscript.md" "$STAGING/Contents/Resources/Validation/large-manuscript.md"
    /usr/libexec/PlistBuddy -c "Add :NRValidationManuscriptResource string Validation/large-manuscript.md" "$STAGING/Contents/Info.plist"
fi
if [[ "$EDITOR_CHECKS" == "1" ]]; then
    /usr/libexec/PlistBuddy -c "Add :NRRunEditorChecks bool true" "$STAGING/Contents/Info.plist"
fi
if [[ "$DROP_CHECKS" == "1" ]]; then
    /usr/libexec/PlistBuddy -c "Add :NRRunDropChecks bool true" "$STAGING/Contents/Info.plist"
fi
if [[ "$FEATURE_CHECKS" == "1" ]]; then
    /usr/libexec/PlistBuddy -c "Add :NRRunFeatureChecks bool true" "$STAGING/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :NRFeaturePhase string $FEATURE_PHASE" "$STAGING/Contents/Info.plist"
fi
if [[ "$METRICS" == "1" ]]; then
    node "$PROJECT_ROOT/script/validation_context.mjs" "$STAGING/Contents/Info.plist" "$VALIDATION_DIRECTORY"
fi
# Finder/File Provider may attach display metadata to the generated bundle.
# Remove only signing-incompatible Finder metadata from this build artifact.
SIGN_ERROR="$PROJECT_ROOT/.cache/signing-error.txt"
verify_generated_bundle() {
    local ARTIFACT="$1"
    local VERIFY_ATTEMPT
    for VERIFY_ATTEMPT in 1 2 3; do
        /usr/bin/xattr -rd com.apple.FinderInfo "$ARTIFACT" 2>/dev/null || true
        /usr/bin/xattr -rd com.apple.ResourceFork "$ARTIFACT" 2>/dev/null || true
        if /usr/bin/codesign --verify --strict "$ARTIFACT" 2>"$SIGN_ERROR"; then return 0; fi
        case "$(cat "$SIGN_ERROR")" in
            *"resource fork, Finder information"*) /bin/sleep 0.5 ;;
            *) cat "$SIGN_ERROR" >&2; return 1 ;;
        esac
    done
    cat "$SIGN_ERROR" >&2
    return 1
}
for SIGN_ATTEMPT in 1 2 3; do
    /usr/bin/xattr -rd com.apple.FinderInfo "$STAGING" 2>/dev/null || true
    /usr/bin/xattr -rd com.apple.ResourceFork "$STAGING" 2>/dev/null || true
    if /usr/bin/codesign --force --sign - "$STAGING" 2>"$SIGN_ERROR"; then break; fi
    if [[ "$SIGN_ATTEMPT" == "3" ]]; then cat "$SIGN_ERROR" >&2; exit 1; fi
    case "$(cat "$SIGN_ERROR")" in
        *"resource fork, Finder information"*) /bin/sleep 0.25 ;;
        *) cat "$SIGN_ERROR" >&2; exit 1 ;;
    esac
done
verify_generated_bundle "$STAGING"
if [[ "$CONFIGURATION" == "release" ]]; then
    /usr/bin/ditto --norsrc --noextattr --noacl -c -k --keepParent "$STAGING" "$STAGING_ROOT/MyEditor.zip"
    node "$PROJECT_ROOT/script/release/create_dmg.mjs" "$STAGING" "$STAGING_ROOT/MyEditor.dmg"
    node "$PROJECT_ROOT/script/release/generate_release_manifest.mjs" \
        --project-root "$PROJECT_ROOT" \
        --bundle "$STAGING" \
        --archive "$STAGING_ROOT/MyEditor.zip" \
        --dmg "$STAGING_ROOT/MyEditor.dmg" \
        --dsym-archive "$DSYM_ARCHIVE_STAGING" \
        --previous-builds "$PROJECT_ROOT/.cache/previous-builds" \
        --budget "$PROJECT_ROOT/Configurations/release-size-budget.json" \
        --output "$RELEASE_MANIFEST"
    node "$PROJECT_ROOT/script/release/publish_release.mjs" "$STAGING_ROOT" "$PROJECT_ROOT/dist" "$PROJECT_ROOT/.cache/previous-builds"
    if ! node "$PROJECT_ROOT/script/release/prune_previous_builds.mjs" --directory "$PROJECT_ROOT/.cache/previous-builds" --keep 3 --apply; then
        echo "Warning: release published; previous build retention needs attention." >&2
    fi
else
    node "$PROJECT_ROOT/script/release/publish_release.mjs" "$STAGING_ROOT" "$PRODUCT_ROOT/$DEBUG_PRODUCT" "$PRODUCT_ROOT/$DEBUG_PRODUCT-backups" debug
    BUNDLE="$PRODUCT_ROOT/$DEBUG_PRODUCT/MyEditor.app"
fi
echo "Built $CONFIGURATION app: $BUNDLE"
if [[ "$LAUNCH" == "0" ]]; then exit 0; fi
/usr/bin/open -n "$BUNDLE"
if [[ "$VERIFY" == "1" || "$DEBUGGER" == "1" ]]; then
    for ATTEMPT in {1..50}; do
        if /usr/bin/pgrep -x "$PROCESS_PATTERN" >/dev/null; then break; fi
        /bin/sleep 0.1
    done
    /usr/bin/pgrep -x "$PROCESS_PATTERN"
fi
if [[ "$DEBUGGER" == "1" ]]; then exec /usr/bin/lldb -p "$(/usr/bin/pgrep -x "$PROCESS_PATTERN" | head -1)"; fi
if [[ "$LOGS" == "1" ]]; then exec /usr/bin/log stream --level info --predicate 'subsystem == "local.novelreader.app"'; fi
