#!/usr/bin/env bash
# Dedicated DEBUG bundle. Never changes the user's installed Claudio bundle or data.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
cd "$repo_root"
regression_output="$(mktemp -d "${TMPDIR:-/tmp}/claudio-native-ui-build.XXXXXX")"
regression_scratch="${CLAUDIO_UI_REGRESSION_SCRATCH:-$regression_output/swift}"
regression_args=(--package-path gui --scratch-path "$regression_scratch" -c debug -Xswiftc -DCLAUDIO_UI_REGRESSION --product ClaudioGUI)
if [[ -n "${CLAUDIO_UI_REGRESSION_SDK:-}" ]]; then regression_args+=(--sdk "$CLAUDIO_UI_REGRESSION_SDK"); fi
swift build "${regression_args[@]}" >&2
regression_bin="$(swift build "${regression_args[@]}" --show-bin-path)"
regression_app="$regression_output/Claudio UI Regression.app"
mkdir -p "$regression_app/Contents/MacOS" "$regression_app/Contents/Resources"
cp "$regression_bin/ClaudioGUI" "$regression_app/Contents/MacOS/ClaudioGUI"
for regression_resource in "$regression_bin"/*_ClaudioGUI.bundle "$regression_bin"/*_ClaudioLocalization.bundle; do
    [[ -d "$regression_resource" ]] || { echo "Missing native resource bundle" >&2; exit 1; }
    cp -R "$regression_resource" "$regression_app/Contents/Resources/"
done
regression_ocr_args=()
if [[ -n "${CLAUDIO_UI_REGRESSION_SDK:-}" ]]; then regression_ocr_args+=( -sdk "$CLAUDIO_UI_REGRESSION_SDK" ); fi
swiftc "${regression_ocr_args[@]}" "$repo_root/scripts/native-ui-screenshot-ocr.swift" -o "$regression_output/screenshot-ocr" >&2
python3 - "$regression_app" "$regression_output" <<'PY'
import hashlib,json,os,pathlib,platform,plistlib,subprocess,sys
app=pathlib.Path(sys.argv[1]); output=pathlib.Path(sys.argv[2])
info={'CFBundleIdentifier':'com.claudio.app.ui-regression','CFBundleName':'Claudio UI Regression','CFBundleExecutable':'ClaudioGUI','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'0.0.0','LSUIElement':True,'NSHighResolutionCapable':True,'ClaudioUIRegressionFixture':'v1'}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
def git(*args): return subprocess.check_output(['git',*args])
tracked=git('ls-files','-z').split(b'\0'); untracked=git('ls-files','--others','--exclude-standard','-z').split(b'\0')
entries=[]
for raw in sorted(set(tracked+untracked)):
 if not raw: continue
 p=pathlib.Path(os.fsdecode(raw)); entries.append({'path':str(p),'sha256':hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else 'deleted'})
fingerprint=hashlib.sha256(json.dumps(entries,sort_keys=True).encode()).hexdigest()
base=git('rev-parse','--verify',os.environ.get('CLAUDIO_UI_REGRESSION_BASE_SHA','30446c56cd010d3d3338b2e8d19618939885319b')+'^{commit}').decode().strip()
manifest={'sourceHEAD':git('rev-parse','HEAD').decode().strip(),'baseSHA':base,'worktreeFingerprint':fingerprint,'sourceFiles':entries,'macOS':platform.mac_ver()[0],'architecture':platform.machine(),'bundle':str(app),'screenshotOCR':str(output/'screenshot-ocr'),'screenshotOCRSHA256':hashlib.sha256((output/'screenshot-ocr').read_bytes()).hexdigest(),'sdk':os.environ.get('CLAUDIO_UI_REGRESSION_SDK','default'),'evidenceBoundary':'DEBUG native fixture; provider and source application are substitutes; no formal acceptance'}
(output/'build-evidence.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
PY
codesign --force --deep --sign - "$regression_app" >&2
codesign --verify --deep --strict "$regression_app" >&2
python3 - "$regression_app" "$regression_output/build-evidence.json" <<'PY'
import hashlib,json,pathlib,sys
app=pathlib.Path(sys.argv[1]); p=pathlib.Path(sys.argv[2]); manifest=json.loads(p.read_text()); records=[]
for file in sorted(app.rglob('*')):
 if file.is_file(): records.append({'path':str(file.relative_to(app)),'sha256':hashlib.sha256(file.read_bytes()).hexdigest(),'bytes':file.stat().st_size})
manifest['bundleFiles']=records;manifest['bundleSHA256']=hashlib.sha256(json.dumps(records,sort_keys=True).encode()).hexdigest();manifest['bundleBytes']=sum(x['bytes'] for x in records);p.write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
print(str(app))
print(str(p))
PY
