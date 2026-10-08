#!/bin/bash
set -euo pipefail
OPENDOCK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPENDOCK_OUTPUT="${1:?usage: extract-app-intents.sh APP_RESOURCES_DIRECTORY}"
OPENDOCK_INPUTS="$OPENDOCK_ROOT/build/app-intents-inputs"
mkdir -p "$OPENDOCK_INPUTS" "$OPENDOCK_OUTPUT"
python3 - "$OPENDOCK_ROOT" "$OPENDOCK_INPUTS" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1]); out=pathlib.Path(sys.argv[2])
sources=sorted((root/'Sources'/'OpenDock').rglob('*.swift'))
combined=root/'build'/'OpenDock-release.swiftconstvalues'
constants=[combined] if combined.exists() and combined.stat().st_size > 2 else []
if not constants:
    for path in (root/'.build').rglob('*.swiftconstvalues'):
        lower=str(path).lower()
        if 'release' in lower and 'test' not in lower and 'opendock' in lower:
            constants.append(path)
if not constants:
    raise SystemExit('No release .swiftconstvalues files. Use Xcode 16+ or enable Swift const-value extraction.')
(out/'sources.txt').write_text('\n'.join(str(x) for x in sources)+'\n')
(out/'constants.txt').write_text('\n'.join(str(x) for x in constants)+'\n')
PY
OPENDOCK_SWIFTC="$(xcrun --find swiftc)"
OPENDOCK_TOOLCHAIN="$(dirname "$(dirname "$(dirname "$OPENDOCK_SWIFTC")")")"
OPENDOCK_SDK="$(xcrun --sdk macosx --show-sdk-path)"
OPENDOCK_XCODE_BUILD="$(xcodebuild -version | awk '/Build version/ {print $3}')"
xcrun appintentsmetadataprocessor \
  --output "$OPENDOCK_OUTPUT" \
  --toolchain-dir "$OPENDOCK_TOOLCHAIN" \
  --module-name OpenDock \
  --sdk-root "$OPENDOCK_SDK" \
  --xcode-version "$OPENDOCK_XCODE_BUILD" \
  --platform-family macOS \
  --deployment-target 13.0 \
  --target-triple "$(uname -m)-apple-macosx13.0" \
  --source-file-list "$OPENDOCK_INPUTS/sources.txt" \
  --swift-const-vals-list "$OPENDOCK_INPUTS/constants.txt"
test -d "$OPENDOCK_OUTPUT/Metadata.appintents"
