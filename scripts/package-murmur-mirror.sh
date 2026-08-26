#!/bin/zsh

set -euo pipefail

repo_root="$(cd "${0:A:h}/.." && pwd)"
cd "${repo_root}"

if ! git diff --quiet || ! git diff --cached --quiet; then
    print -u2 "Refusing to package tracked changes that are not committed."
    exit 1
fi

xcode_app="${XCODE_APP:-/Applications/Xcode.app}"
developer_dir="${xcode_app}/Contents/Developer"
[[ -x "${developer_dir}/usr/bin/xcodebuild" ]] || {
    print -u2 "Xcode was not found at ${xcode_app}."
    exit 1
}
command -v xcodegen >/dev/null || {
    print -u2 "xcodegen is required on the build Mac."
    exit 1
}

full_sha="$(git rev-parse HEAD)"
short_sha="$(git rev-parse --short=12 HEAD)"
package_name="murmur-mirror-mac-mini-${short_sha}"
dist_dir="${repo_root}/dist"
archive_path="${dist_dir}/${package_name}.zip"
temporary_root="$(/usr/bin/mktemp -d -t murmur-mirror-package)"
derived_data="${temporary_root}/DerivedData"
package_root="${temporary_root}/${package_name}"

cleanup() {
    /bin/rm -rf "${temporary_root}"
}
trap cleanup EXIT

print "Generating Xcode project..."
xcodegen generate >/dev/null

print "Building universal murmur-mirror..."
DEVELOPER_DIR="${developer_dir}" /usr/bin/xcodebuild \
    -project doubao-murmur.xcodeproj \
    -scheme murmur-mirror \
    -configuration Release \
    -derivedDataPath "${derived_data}" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    build

built_helper="${derived_data}/Build/Products/Release/murmur-mirror"
[[ -x "${built_helper}" ]]
/bin/mkdir -p "${package_root}"
/bin/cp "${built_helper}" "${package_root}/murmur-mirror"
/usr/bin/codesign --force --sign - --identifier com.doubao.murmur.mirror "${package_root}/murmur-mirror"
/usr/bin/codesign --verify --strict "${package_root}/murmur-mirror"

archs="$(/usr/bin/lipo -archs "${package_root}/murmur-mirror")"
[[ " ${archs} " == *" arm64 "* && " ${archs} " == *" x86_64 "* ]] || {
    print -u2 "Universal architecture check failed: ${archs}"
    exit 1
}

/bin/cp packaging/murmur-mirror/install.command "${package_root}/install.command"
/bin/cp packaging/murmur-mirror/verify.command "${package_root}/verify.command"
/bin/cp packaging/murmur-mirror/com.doubao.murmur.mirror.plist "${package_root}/com.doubao.murmur.mirror.plist"
/bin/cp packaging/murmur-mirror/README.md "${package_root}/README.md"
/bin/chmod 0755 "${package_root}/install.command" "${package_root}/verify.command" "${package_root}/murmur-mirror"

(
    cd "${package_root}"
    /usr/bin/shasum -a 256 murmur-mirror > murmur-mirror.sha256
)

{
    print "source_commit=${full_sha}"
    print "source_branch=$(git branch --show-current)"
    print "architectures=${archs}"
    print "minimum_macos=13.0"
    print "signature=ad-hoc"
    print "notarized=no"
    print "built_at_utc=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${package_root}/BUILD-INFO.txt"

/usr/bin/plutil -lint "${package_root}/com.doubao.murmur.mirror.plist" >/dev/null
/bin/zsh -n "${package_root}/install.command" "${package_root}/verify.command"

/bin/mkdir -p "${dist_dir}"
/bin/rm -f "${archive_path}"
(
    cd "${temporary_root}"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "${package_name}" "${archive_path}"
)

print "Created ${archive_path}"
print "Archive SHA-256: $(/usr/bin/shasum -a 256 "${archive_path}" | /usr/bin/awk '{print $1}')"
