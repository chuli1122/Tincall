#!/bin/bash
# SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
# SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

# Build a source edition IPA and its library materials. Does not sign or publish.
set -euo pipefail

if [ "$#" -ne 1 ] || [ "$1" = --help ]; then
    echo "Usage: bash tools/package-self-sign.sh NEW_OUTPUT_DIRECTORY"
    echo "Requires macOS and Xcode. Output must be outside the source tree and not exist."
    [ "${1:-}" = --help ] && exit 0
    exit 1
fi
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
task_output=$(python3 - "$task_root" "$1" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).resolve()
requested = Path(sys.argv[2]).expanduser()
output = requested.resolve()
if requested.is_symlink() or output.exists() or output == source or source in output.parents:
    raise SystemExit("Choose a new output directory outside the source tree.")
output.mkdir(parents=True)
print(output)
PY
)

xcodebuild -project "$task_root/ios/Tincall.xcodeproj" \
    -scheme Tincall -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath "$task_output/DerivedData" \
    -archivePath "$task_output/Tincall.xcarchive" \
    -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO archive \
    > "$task_output/build.log" 2>&1 || {
        echo "Build failed; see $task_output/build.log" >&2
        exit 1
    }

task_app="$task_output/Tincall.xcarchive/Products/Applications/Tincall.app"
# Xcode leaves linker ad-hoc signatures on some frameworks; they carry no identity
# and are replaced when the recipient re-signs, so strip them before checking.
find "$task_app" \( -name '*.framework' -o -name '*.dylib' -o -name '*.appex' \) -print0 |
    while IFS= read -r -d '' task_bundle; do
        codesign --remove-signature "$task_bundle" 2>/dev/null || true
    done
codesign --remove-signature "$task_app" 2>/dev/null || true
task_name=$(python3 - "$task_app" <<'PY'
from pathlib import Path
import plistlib
import re
import subprocess
import sys
app = Path(sys.argv[1])
def info(path):
    with path.open('rb') as stream:
        return plistlib.load(stream)
main = info(app / 'Info.plist')
extensions = sorted(app.rglob('*.appex'))
expected = {'TincallCallWidget.appex', 'TincallCallIntents.appex'}
missing = expected - {extension.name for extension in extensions}
if missing:
    raise SystemExit('Missing required app extension: ' + ', '.join(sorted(missing)))
for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', main[key]):
        raise SystemExit('App version and build must be numeric.')
    for extension in extensions:
        if info(extension / 'Info.plist')[key] != main[key]:
            raise SystemExit(f'App and {extension.name} must have the same {key}.')
for name in ('LAME-LICENSE.txt', 'ONNXRuntime-LICENSE.txt',
             'ONNXRuntime-ThirdPartyNotices.txt', 'SileroVAD-LICENSE.txt',
             'Frameworks/LAME.framework/LAME'):
    if not (app / name).is_file():
        raise SystemExit('Missing packaged library or notice: ' + name)
for path in app.rglob('*'):
    if path.name == '_CodeSignature' or path.suffix == '.mobileprovision':
        raise SystemExit('An unsigned public IPA must not contain signatures or profiles: ' + str(path))
for bundle in [app, *extensions, *app.rglob('*.framework'), *app.rglob('*.dylib')]:
    if subprocess.run(['codesign', '-d', str(bundle)], stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL).returncode == 0:
        raise SystemExit('An unsigned public IPA must not contain signed code: ' + str(bundle))
print('Tincall-' + main['CFBundleShortVersionString'] + '-build' + main['CFBundleVersion'])
PY
)

mkdir -p "$task_output/package/Payload" "$task_output/LibraryMaterials/Notices"
ditto "$task_app" "$task_output/package/Payload/Tincall.app"
ditto -c -k --keepParent "$task_output/package/Payload" "$task_output/$task_name-selfsign-unsigned.ipa"
# Include only the library source, not package caches or local build products.
tar -C "$task_root/ios/LocalPackages" --exclude=.build --exclude=.swiftpm -cf - LAME |
    tar -C "$task_output/LibraryMaterials" -xf -
cp "$task_app/LAME-LICENSE.txt" "$task_app/ONNXRuntime-LICENSE.txt" \
    "$task_app/ONNXRuntime-ThirdPartyNotices.txt" "$task_app/SileroVAD-LICENSE.txt" \
    "$task_output/LibraryMaterials/Notices/"
cat > "$task_output/BUILD.txt" <<EOF
Product: $task_name
Edition: source / personal self-signing (no StoreKit call gate)
Scheme: Tincall
Configuration: Release
Signing: disabled; the recipient must re-sign the app, both extensions and frameworks
Source: distribute the reviewed source snapshot from this same build with the IPA
Libraries: LAME 3.100 (dynamic), ONNX Runtime 1.24.2, bundled Silero VAD
Library materials: LibraryMaterials/ (include the entire directory with the IPA)
Build log: build.log (local only; do not publish build logs or archives)
EOF
xcodebuild -version >> "$task_output/BUILD.txt"
ditto -c -k --keepParent "$task_output/LibraryMaterials" "$task_output/$task_name-library-materials.zip"
echo "Created $task_output/$task_name-selfsign-unsigned.ipa"
echo "Created $task_output/$task_name-library-materials.zip and BUILD.txt"
echo "No signing, device installation, upload or publication was performed."
