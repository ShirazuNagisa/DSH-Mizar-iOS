#!/bin/zsh
set -eu
cd "${0:A:h}/../.."
task_root="$PWD"
task_started=$(date +%s)
task_out="$task_root/.devcache/live-activity-validation"
task_app="$task_out/ProductionValidation.app"
task_simulator="${MIZAR_VALIDATION_SIMULATOR:-C1A86C33-CCC0-448A-80BD-B815D9E2783A}"
task_products="${MIZAR_VALIDATION_PRODUCTS:-$task_root/.devcache/DerivedData/Build/Products/Debug-iphonesimulator}"
task_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
mkdir -p "$task_app"
cat DSH-Mizar-LiveActivity/DSHMizarLiveActivityWidget.swift DesignValidation/LiveActivity/Host.swift > "$task_out/Production.swift"
python3 - "$task_app" <<'PY'
import plistlib,sys
from pathlib import Path
app=Path(sys.argv[1])
(app/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='me.shirazu.mizar.production-validation',CFBundleExecutable='ProductionValidation',CFBundleName='ProductionValidation',CFBundleVersion='1',CFBundleShortVersionString='1.0',CFBundlePackageType='APPL',MinimumOSVersion='26.0',UIDeviceFamily=[1,2],UILaunchScreen={})))
PY
cp -R DSH-Mizar-LiveActivity/zh-Hans.lproj "$task_app/"
cp -R DSH-Mizar-LiveActivity/en.lproj "$task_app/"
xcrun --sdk iphonesimulator swiftc -parse-as-library -swift-version 6 -target arm64-apple-ios26.0-simulator -sdk "$task_sdk" -F "$task_products" -framework MizarKit "$task_out/Production.swift" -o "$task_app/ProductionValidation"
if [ -f "$task_products/DSH-Mizar-LiveActivity.appex/Assets.car" ]; then
  cp "$task_products/DSH-Mizar-LiveActivity.appex/Assets.car" "$task_app/Assets.car"
fi
codesign --force --sign - "$task_app"
xcrun simctl boot "$task_simulator" 2>/dev/null || true
xcrun simctl bootstatus "$task_simulator" -b >/dev/null
xcrun simctl terminate "$task_simulator" me.shirazu.mizar.production-validation 2>/dev/null || true
xcrun simctl install "$task_simulator" "$task_app"
xcrun simctl launch "$task_simulator" me.shirazu.mizar.production-validation

task_container=$(xcrun simctl get_app_container "$task_simulator" me.shirazu.mizar.production-validation data)
python3 - "$task_container" "$task_out" "$task_started" "$task_root" <<'PY'
import hashlib,json,shutil,sys,time
from pathlib import Path
source=Path(sys.argv[1])/'Documents/ProductionExports'
output=Path(sys.argv[2])/'exports';started=float(sys.argv[3]);root=Path(sys.argv[4])
for _ in range(150):
 try:
  rows=json.loads((source/'measurements.json').read_text())
  if len(rows)==90 and rows[0].get('generatedAt',0)>=started-1: break
 except (OSError,ValueError): pass
 time.sleep(.2)
else: raise SystemExit('No fresh production layout measurements')
output.mkdir(parents=True,exist_ok=True)
for row in rows: shutil.copy2(source/(row['name']+'.png'),output)
shutil.copy2(source/'measurements.json',output)
summary={
 'cases':len(rows),
 'failed':[row for row in rows if not row['passed']],
 'maxHeight':max(row['height'] for row in rows),
 'widgetSHA256':hashlib.sha256((root/'DSH-Mizar-LiveActivity/DSHMizarLiveActivityWidget.swift').read_bytes()).hexdigest(),
 'mizarKitLiveActivitySHA256':hashlib.sha256((root/'MizarKit/Sources/MizarKit/LiveActivity.swift').read_bytes()).hexdigest(),
 'mizarKitLiveActivityProjectionSHA256':hashlib.sha256((root/'MizarKit/Sources/MizarKit/LiveActivityProjection.swift').read_bytes()).hexdigest(),
 'scope':'production Lock Screen card leaf; expanded system UI verified separately',
}
(output/'validation-summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(summary,ensure_ascii=False))
assert not summary['failed']
PY
