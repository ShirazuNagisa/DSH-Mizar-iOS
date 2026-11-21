#!/usr/bin/env bash
#
# Pre-merge gate: the local, CI-shaped minimum before a merge.
#
#   scripts/pre-merge.sh            # kernel suite + unit suite + snapshot suite + selection plan
#   scripts/pre-merge.sh --with-ui  # also actually run the selected UI subset
#
# The snapshot device is picked at run time: `MIZAR_SIMULATOR` if set, else the
# canonical `Mizar Runs`, else the first available iPhone. Snapshot references
# were recorded on `Mizar Runs`; on another device a mismatch may be the device,
# not the change (docs/snapshots.md).
#
# Never runs the live layer; a default regression must not touch a real host.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SNAP_DERIVED=".devcache/DerivedData-snap"

# Print "<name>|<udid>" for the simulator to use. Preference order:
# MIZAR_SIMULATOR, "Mizar Runs", then the first available iPhone. `simctl list -j`
# is parsed with node (already a dependency of the kernel suite), so a renamed or
# missing device degrades to another phone instead of failing the whole gate.
pick_simulator() {
  xcrun simctl list devices available -j | node -e '
    let raw = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => { raw += chunk; });
    process.stdin.on("end", () => {
      const preferred = process.argv[1] || "";
      const all = Object.values(JSON.parse(raw).devices || {}).flat();
      const phones = all.filter((d) => d && d.isAvailable && /^iPhone/.test(d.name));
      const chosen = phones.find((d) => d.name === preferred) || phones[0];
      if (!chosen) process.exit(1);
      process.stdout.write(chosen.name + "|" + chosen.udid);
      if (preferred && chosen.name !== preferred) {
        process.stderr.write(`pre-merge: ${preferred} 不可用，改用 ${chosen.name}（${chosen.udid}）\n`);
      }
    });
  ' "${MIZAR_SIMULATOR:-Mizar Runs}"
}

WITH_UI=0
[ "${1:-}" = "--with-ui" ] && WITH_UI=1

if pgrep -f "xcodebuild -project" >/dev/null 2>&1; then
  echo "pre-merge: another xcodebuild is running; wait for it (parallel runs wedge testmanagerd)" >&2
  exit 1
fi

t0=$(date +%s)

echo "== 1/4 kernel suite (typecheck, vitest, bundle) =="
( cd LocalKernel/kernel && npm run verify ) 2>&1 | tail -2
t1=$(date +%s)
echo "pre-merge: kernel $((t1-t0))s"

echo "== 2/4 unit suite (host, whole) =="
scripts/swift.sh test 2>&1 | tail -2
t2=$(date +%s)
echo "pre-merge: unit $((t2-t1))s"

echo "== 3/4 snapshot suite =="
SIM_SPEC="$(pick_simulator)" || {
  echo "pre-merge: 没有可用的 iPhone 模拟器（xcrun simctl list devices available 为空）" >&2
  exit 1
}
SIMULATOR="${SIM_SPEC%%|*}"
SIM_UDID="${SIM_SPEC##*|}"
echo "pre-merge: simulator $SIMULATOR ($SIM_UDID)"
if [ "$SIMULATOR" != "Mizar Runs" ]; then
  echo "pre-merge: 注意：快照基准录制于 Mizar Runs；换设备的失败要先排除设备因素（docs/snapshots.md）" >&2
fi
xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null 2>&1 || true
xcodebuild test \
  -project DSH-Mizar.xcodeproj \
  -scheme DSH-Mizar-Snapshots \
  -destination "platform=iOS Simulator,id=$SIM_UDID" \
  -derivedDataPath "$SNAP_DERIVED" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  -collect-test-diagnostics never 2>&1 | tail -3
t3=$(date +%s)
echo "pre-merge: snapshots $((t3-t2))s"

echo "== 4/4 test selection =="
if [ "$WITH_UI" = "1" ]; then
  scripts/test-select.sh --simulator "$SIMULATOR"
else
  scripts/test-select.sh --dry-run --simulator "$SIMULATOR"
fi
t4=$(date +%s)
echo "pre-merge: selection $((t4-t3))s"

echo "pre-merge: all gates finished in $((t4-t0))s"
