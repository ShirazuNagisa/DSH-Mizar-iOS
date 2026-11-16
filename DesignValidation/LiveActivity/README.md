# Production Live Activity layout validation

## Purpose and matrix

This directory hosts the native validation harness for the production Lock Screen Live Activity card leaf. It renders the production widget and host view into simulator exports and checks a 90-case matrix: widths 371, 380, and 408 pt; six Dynamic Type sizes; and five content scenarios.

The harness covers Lock Screen card layout. It does not measure the Dynamic Island system presentation and does not validate real remote approvals or device interaction.

## Run

Run from the iOS worktree root:

```sh
DesignValidation/LiveActivity/validate.sh
```

Override the simulator UDID or the Xcode simulator products directory when needed. The products directory must contain `MizarKit.framework`; the script uses the extension's `Assets.car` when present.

```sh
MIZAR_VALIDATION_SIMULATOR=<simulator-udid> \
MIZAR_VALIDATION_PRODUCTS=<simulator-products-directory> \
DesignValidation/LiveActivity/validate.sh
```

When omitted, the script uses its configured simulator UDID and `.devcache/DerivedData/Build/Products/Debug-iphonesimulator` under the iOS worktree. It writes the validation app and exports under `.devcache/live-activity-validation/`.

## Fresh-output check

Each run records its start time and accepts measurements only when a fresh `measurements.json` contains exactly 90 rows whose `generatedAt` is at or after that run's start. It copies the PNGs and measurements into `exports/`, writes `validation-summary.json` with case failures, maximum height, and source hashes, and exits unsuccessfully if the measurements are stale, the case count is not 90, or any case failed.

## Workspace report and evidence

The implementation status, source-hash interpretation, archived exports, and device observations are maintained in the workspace [production implementation report](../../../DSH-Mizar/docs/ios/live-activity-production-implementation-2026-11-16.md) and [evidence directory](../../../DSH-Mizar/docs/evidence/ios-live-activity-redesign-2026-11-15/production-layout/). Check the report before treating an archived matrix as evidence for the current Widget source; the report records the exact source hash associated with each export.
