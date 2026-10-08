#!/bin/bash
set -euo pipefail
OPENDOCK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPENDOCK_OUTPUT="${1:?usage: extract-app-intents.sh APP_RESOURCES_DIRECTORY}"
OPENDOCK_INPUTS="$OPENDOCK_ROOT/build/app-intents-inputs"
mkdir -p "$OPENDOCK_INPUTS" "$OPENDOCK_OUTPUT"
python3 - "$OPENDOCK_ROOT" "$OPENDOCK_INPUTS" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]); out=pathlib.Path(sys.argv[2])
sources=sorted((root/'Sources'/'OpenDock').rglob('*.swift'))
combined=root/'build'/'OpenDock-release.swiftconstvalues'
required={'OpenDock.DockProfileEntity','OpenDock.DockProfileQuery','OpenDock.SwitchDockFocusFilter',
          'OpenDock.SwitchDockIntent','OpenDock.OpenDockShortcuts'}
def extracted_types(path):
    try:
        records=json.loads(path.read_text())
        if not isinstance(records,list): return set()
        records=[r for r in records if isinstance(r,dict) and r.get('typeName','').startswith('OpenDock.')]
        for record in records:
            source=pathlib.Path(record.get('file',''))
            if not source.is_absolute(): source=root/source
            if source.is_file() and source.stat().st_mtime_ns > path.stat().st_mtime_ns:
                return set() # Never package stale constants after an intent source edit.
        return {r['typeName'] for r in records}
    except (OSError,ValueError,TypeError): return set()
constants=[]; found=set()
if combined.exists() and required <= extracted_types(combined):
    constants=[combined]; found=required
else:
    # Some SwiftPM/Xcode build engines manage their own supplementary paths.
    candidates=[]
    for path in (root/'.build').rglob('*.swiftconstvalues'):
        parts=[p.lower() for p in path.relative_to(root/'.build').parts]
        if 'release' in parts and not any('test' in p for p in parts): candidates.append(path)
    for path in sorted(candidates,key=lambda p:p.stat().st_mtime_ns,reverse=True):
        types=extracted_types(path)
        if not types or types & found: continue
        constants.append(path); found |= types
        if required <= found: break
if not required <= found:
    missing=', '.join(sorted(required-found))
    raise SystemExit('Missing current release App Intents constants: '+missing+'. Run scripts/build-app.sh with a compatible Xcode 16+ toolchain.')
(out/'sources.txt').write_text('\n'.join(str(x) for x in sources)+'\n')
(out/'constants.txt').write_text('\n'.join(str(x) for x in constants)+'\n')
PY
OPENDOCK_SWIFTC="${SWIFT_EXEC:-$(xcrun --find swiftc)}"
OPENDOCK_TOOLCHAIN="$(dirname "$(dirname "$(dirname "$OPENDOCK_SWIFTC")")")"
OPENDOCK_SDK="$(xcrun --sdk macosx --show-sdk-path)"
OPENDOCK_XCODE_BUILD="$(xcodebuild -version | awk '/Build version/ {print $3}')"
OPENDOCK_STAGE="$(mktemp -d "$OPENDOCK_OUTPUT/.opendock-intents.XXXXXX")"
trap 'rm -rf "$OPENDOCK_STAGE"' EXIT
xcrun appintentsmetadataprocessor \
  --output "$OPENDOCK_STAGE" \
  --toolchain-dir "$OPENDOCK_TOOLCHAIN" \
  --module-name OpenDock \
  --sdk-root "$OPENDOCK_SDK" \
  --xcode-version "$OPENDOCK_XCODE_BUILD" \
  --platform-family macOS \
  --deployment-target 13.0 \
  --target-triple "$(uname -m)-apple-macosx13.0" \
  --source-file-list "$OPENDOCK_INPUTS/sources.txt" \
  --swift-const-vals-list "$OPENDOCK_INPUTS/constants.txt"
python3 - "$OPENDOCK_STAGE/Metadata.appintents/extract.actionsdata" <<'PY'
import json,pathlib,sys
path=pathlib.Path(sys.argv[1])
try:
    data=json.loads(path.read_text())
    actions=data.get('actions',{})
    names={name.rsplit('.',1)[-1] for name in actions}
    if not {'SwitchDockIntent','SwitchDockFocusFilter'} <= names or not data.get('entities') or not data.get('autoShortcuts'):
        raise ValueError('switch action, Focus filter, profile entity, or App Shortcut is missing')
except (OSError,ValueError,TypeError,AttributeError) as error:
    raise SystemExit('App Intents metadata extraction did not produce complete metadata: '+str(error))
print('Verified App Intents metadata: switch action, Focus filter, profile entity, and App Shortcut.')
PY
rm -rf "$OPENDOCK_OUTPUT/Metadata.appintents"
mv "$OPENDOCK_STAGE/Metadata.appintents" "$OPENDOCK_OUTPUT/Metadata.appintents"
