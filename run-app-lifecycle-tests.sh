#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/timer-lifecycle.XXXXXX")"
trap 'rm -r "$BUILD"' EXIT
mkdir -p "$BUILD/modules"

core_sources=("$ROOT"/TimerCore/Sources/TimerCore/*.swift)

swiftc -swift-version 6 -strict-concurrency=complete \
  -emit-library -emit-module -module-name TimerCore \
  -emit-module-path "$BUILD/modules/TimerCore.swiftmodule" \
  "${core_sources[@]}" \
  -o "$BUILD/modules/libTimerCore.dylib"

swiftc -swift-version 6 -strict-concurrency=complete \
  -I "$BUILD/modules" -L "$BUILD/modules" -lTimerCore \
  "$ROOT/20-20-20-timer/TimerCommandProtocol/TimerCommandProtocol.swift" \
  "$ROOT/20-20-20-timer/20-20-20-timer/CheckInPreferences.swift" \
  "$ROOT/20-20-20-timer/20-20-20-timer/TimerController.swift" \
  "$ROOT/20-20-20-timer/20-20-20-timer/TimerCommandService.swift" \
  "$ROOT/app-tests/TimerLifecycleHarness.swift" \
  -o "$BUILD/lifecycle-harness"

DYLD_LIBRARY_PATH="$BUILD/modules" "$BUILD/lifecycle-harness"
