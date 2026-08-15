#!/usr/bin/env bash
# Repeatable LifeLog verification tiers, built on xcodebuild and simctl only.
# Usage: scripts/verify.sh <fast|data|ui-smoke|full|device-checklist>
# See scripts/VERIFY.md for what each tier covers and how to read its output.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PROJECT="$REPO_ROOT/LifeLog.xcodeproj"
SPEC="$REPO_ROOT/project.yml"
SCHEME="LifeLog"
DEVICE_MODEL="iPhone 17 Pro Max"
XCODEGEN_BIN="$REPO_ROOT/.tools/xcodegen/bin/xcodegen"

VERIFY_ROOT="${LIFELOG_VERIFY_DIR:-${TMPDIR:-/tmp}/lifelog-verify}"
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$VERIFY_ROOT/$RUN_STAMP"
LOG_DIR="$RUN_DIR/logs"
DERIVED_FOCUSED="$VERIFY_ROOT/derived-focused"
DERIVED_UI="$VERIFY_ROOT/derived-ui"

# The four ActivityLocationPolicy/InsightsSnapshot suites plus the scattered
# schema/backup/import/resolver classes that make up the "data" tier. Kept as
# one list so "fast" (skip these) and "data" (only these) can never drift
# apart from each other.
DATA_TEST_IDENTIFIERS=(
  "LifeLogTests/SchemaMigrationTests"
  "LifeLogTests/LocalBackupTests"
  "LifeLogTests/CurrentVisitInvariantTests"
  "LifeLogTests/DepartureMatchingTests"
  "LifeLogTests/DuplicateCallbackTests"
  "LifeLogTests/IgnoredAndConfirmedChoiceTests"
  "LifeLogTests/ImportedHistoryInteractionTests"
  "LifeLogTests/OverlapResolutionTests"
  "LifeLogTests/PresentationAndDiagnosticsTests"
  "LifeLogTests/TravelConstructionTests"
  "LifeLogTests/IncrementalLocationResolutionTests"
  "LifeLogTests/VisitResolutionStateTests"
  "LifeLogTests/LocationArrivalConfirmationTests"
  "LifeLogTests/PlaceScoringTests"
  "LifeLogTests/ActivityImportActorTests"
  "LifeLogTests/MalformedFixturesAndImportExportTests"
  "LifeLogTests/ResolverPerformanceTests"
)

# One representative, seed-deterministic check per named area. Not the full
# UI suite - see scripts/VERIFY.md for why these four were picked.
UI_SMOKE_IDENTIFIERS=(
  "LifeLogUITests/AccessibilitySmokeTests/testPrimaryScreensExposeStableAccessibilityHooks"
  "LifeLogUITests/InsightsDayTests/testInsightsDayShowsCurrentActivityCard"
  "LifeLogUITests/TimelineAndActivitiesTests/testActivityVisitsAreListedAndEditable"
  "LifeLogUITests/SettingsAndDiagnosticsTests/testSavedPlaceRoleControlIsReachable"
)

log()  { printf '[verify] %s\n' "$*"; }
warn() { printf '[verify] WARN: %s\n' "$*" >&2; }
fail() { printf '[verify] FAIL: %s\n' "$*" >&2; exit 1; }

require_tools() {
  command -v xcodebuild >/dev/null || fail "xcodebuild not found."
  command -v xcrun >/dev/null || fail "xcrun not found."
  command -v jq >/dev/null || fail "jq not found (brew install jq) - needed to parse xcresult summaries."
  [[ -x "$XCODEGEN_BIN" ]] || fail "Repository XcodeGen binary missing at $XCODEGEN_BIN. This script only uses the vendored copy, not any Homebrew/global xcodegen."
}

# --- project regeneration -----------------------------------------------

regenerate_and_verify_project() {
  mkdir -p "$LOG_DIR"
  local xcodegen_version drift
  xcodegen_version="$("$XCODEGEN_BIN" version 2>/dev/null | sed -n 's/^Version: //p')"
  log "Regenerating $PROJECT from project.yml with repository XcodeGen $xcodegen_version"
  if ! "$XCODEGEN_BIN" generate --spec "$SPEC" --project "$REPO_ROOT" >"$LOG_DIR/xcodegen.log" 2>&1; then
    fail "xcodegen generate failed - see $LOG_DIR/xcodegen.log"
  fi
  if command -v git >/dev/null && git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    drift="$(git -C "$REPO_ROOT" status --porcelain -- LifeLog.xcodeproj/project.pbxproj)"
    if [[ -n "$drift" ]]; then
      warn "LifeLog.xcodeproj did not match project.yml before this run - it has been regenerated in the working tree (not committed)."
      git -C "$REPO_ROOT" --no-pager diff --stat -- LifeLog.xcodeproj/project.pbxproj | sed 's/^/[verify]   /'
    else
      log "LifeLog.xcodeproj already matched project.yml - no drift."
    fi
  else
    warn "Not a git work tree - cannot report project.pbxproj drift."
  fi
}

# --- simulator destination ------------------------------------------------

# Resolves to a UDID, never a device name, and never boots the Simulator GUI:
# xcodebuild/simctl drive the simulator process headlessly. Prefers a device
# that is already Booted so a run doesn't fight another booted instance.
resolve_simulator_udid() {
  local json
  json="$(xcrun simctl list devices available -j)" || fail "simctl list devices failed."
  SIM_UDID="$(printf '%s' "$json" | jq -r --arg name "$DEVICE_MODEL" '
    [.devices[][] | select(.name == $name)]
    | (map(select(.state == "Booted")) + .)
    | .[0].udid // empty
  ')"
  if [[ -z "${SIM_UDID:-}" ]]; then
    fail "No \"$DEVICE_MODEL\" simulator is available. Create one first, e.g.:
  xcrun simctl create \"$DEVICE_MODEL\" \"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max\" <runtime-id>
(list runtimes with: xcrun simctl list runtimes)"
  fi
  local state
  state="$(xcrun simctl list devices -j | jq -r --arg udid "$SIM_UDID" '.devices[][] | select(.udid == $udid) | .state')"
  if [[ "$state" != "Booted" ]]; then
    log "Booting simulator $SIM_UDID headlessly (simctl only, no Simulator.app)."
    xcrun simctl boot "$SIM_UDID" >/dev/null 2>&1 || true
  fi
  log "Resolved destination: $DEVICE_MODEL ($SIM_UDID, $state)"
  DESTINATION="id=$SIM_UDID"
}

# --- run + verify one xcodebuild invocation -------------------------------

fresh_derived_data() {
  local path="$1"
  rm -rf "$path"
  mkdir -p "$path"
}

# Runs xcodebuild, tees output to a per-label log, and only returns success
# if: xcodebuild exited 0, the expected success marker is present in the log,
# the resultBundle (when one was requested) has an Info.plist (an incomplete/
# wedged bundle is missing it and xcresulttool refuses to read it), and - for
# test actions - at least one test actually executed.
run_xcodebuild() {
  local label="$1" marker="$2" expect_tests="$3"; shift 3
  local logfile="$LOG_DIR/$label.log"
  local resultbundle="$RUN_DIR/$label.xcresult"
  mkdir -p "$LOG_DIR"

  log "== $label =="
  log "xcodebuild $* -resultBundlePath $resultbundle"

  xcodebuild "$@" -resultBundlePath "$resultbundle" > >(tee "$logfile") 2>&1
  local status=$?

  log "log:      $logfile"
  log "xcresult: $resultbundle"

  if [[ $status -ne 0 ]]; then
    fail "$label: xcodebuild exited $status - see $logfile"
  fi
  if ! grep -F -q -- "$marker" "$logfile"; then
    fail "$label: xcodebuild exited 0 but never printed \"$marker\" - see $logfile"
  fi

  if [[ ! -d "$resultbundle" || ! -f "$resultbundle/Info.plist" ]]; then
    fail "$label: $resultbundle is missing or has no Info.plist - treat as an incomplete/wedged result bundle, not a pass."
  fi

  if [[ "$expect_tests" == "tests" ]]; then
    local summary total failed result
    summary="$(xcrun xcresulttool get test-results summary --path "$resultbundle" --format json 2>"$LOG_DIR/$label.xcresulttool-error.log")" \
      || fail "$label: xcresulttool could not read $resultbundle - treat as incomplete, see $LOG_DIR/$label.xcresulttool-error.log"
    total="$(printf '%s' "$summary" | jq -r '.totalTestCount // 0')"
    failed="$(printf '%s' "$summary" | jq -r '.failedTests // 0')"
    result="$(printf '%s' "$summary" | jq -r '.result // "Unknown"')"
    log "$label: $total tests executed, $failed failed, result=$result"
    if [[ "$total" -eq 0 ]]; then
      fail "$label: xcodebuild reported success but 0 tests executed - the -only-testing filter probably matched nothing."
    fi
    if [[ "$result" != "Passed" || "$failed" -ne 0 ]]; then
      fail "$label: $failed of $total tests failed - see $logfile / $resultbundle"
    fi
  fi

  log "$label: OK"
}

# Bash on macOS is stuck at 3.2 (no mapfile/readarray), so flags are built
# into a global array by name rather than returned through a subshell.
build_only_testing_flags() {
  local __outvar="$1"; shift
  local __tmp=()
  for id in "$@"; do __tmp+=("-only-testing:$id"); done
  eval "$__outvar=(\"\${__tmp[@]}\")"
}

build_skip_testing_flags() {
  local __outvar="$1"; shift
  local __tmp=()
  for id in "$@"; do __tmp+=("-skip-testing:$id"); done
  eval "$__outvar=(\"\${__tmp[@]}\")"
}

# --- tiers -----------------------------------------------------------------

tier_fast() {
  fresh_derived_data "$DERIVED_FOCUSED"
  local skip=()
  build_skip_testing_flags skip "${DATA_TEST_IDENTIFIERS[@]}"
  run_xcodebuild "fast-build" "** TEST BUILD SUCCEEDED **" "build" \
    -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_FOCUSED" build-for-testing -skip-testing:LifeLogUITests
  # "** TEST EXECUTE SUCCEEDED **", not the "** TEST SUCCEEDED **" every other
  # tier expects: this is the only tier that splits the build from the run, and
  # test-without-building prints the EXECUTE form. Asking for the wrong one made
  # `fast` incapable of reporting a pass -- every run ended in a marker FAIL after
  # its tests had all passed, which reads exactly like a real failure.
  run_xcodebuild "fast-unit-tests" "** TEST EXECUTE SUCCEEDED **" "tests" \
    -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_FOCUSED" test-without-building -only-testing:LifeLogTests "${skip[@]}"
  report_version_alignment "$DERIVED_FOCUSED"
}

tier_data() {
  fresh_derived_data "$DERIVED_FOCUSED"
  local only=()
  build_only_testing_flags only "${DATA_TEST_IDENTIFIERS[@]}"
  run_xcodebuild "data-tests" "** TEST SUCCEEDED **" "tests" \
    -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_FOCUSED" test "${only[@]}"
}

tier_ui_smoke() {
  fresh_derived_data "$DERIVED_UI"
  local only=()
  build_only_testing_flags only "${UI_SMOKE_IDENTIFIERS[@]}"
  run_xcodebuild "ui-smoke" "** TEST SUCCEEDED **" "tests" \
    -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_UI" test "${only[@]}"
}

tier_full() {
  fresh_derived_data "$DERIVED_FOCUSED"
  run_xcodebuild "full-unit-tests" "** TEST SUCCEEDED **" "tests" \
    -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_FOCUSED" test -only-testing:LifeLogTests
  report_version_alignment "$DERIVED_FOCUSED"

  fresh_derived_data "$DERIVED_UI"
  run_xcodebuild "full-ui-tests" "** TEST SUCCEEDED **" "tests" \
    -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_UI" test -only-testing:LifeLogUITests
}

tier_device_checklist() {
  cat <<'EOF'
[verify] device-checklist is informational only. It never erases, reinstalls
[verify] over, or otherwise touches an on-device store, and it never opens
[verify] the Simulator GUI - a simulator PASS on fast/data/ui-smoke/full
[verify] proves the app's own logic, not sensor behaviour. Geofencing, the
[verify] Wi-Fi anchor, motion collection, and HealthKit only run for real on
[verify] hardware; nothing in this script can substitute for the checklist
[verify] below on the owner's iPhone 17 Pro Max.
EOF
  echo
  log "Looking for a connected iPhone 17 Pro Max (read-only query, xcrun devicectl)..."
  if command -v xcrun >/dev/null && xcrun devicectl list devices >/dev/null 2>&1; then
    xcrun devicectl list devices 2>/dev/null | tee "$LOG_DIR/devicectl.log" || true
  else
    warn "xcrun devicectl unavailable or no device reachable - connect and unlock the iPhone, trust this Mac, and re-run this tier to confirm it's visible."
  fi
  echo
  cat <<EOF
[verify] Manual checklist (from PERFORMANCE_BUDGETS.md - run all steps on
[verify] the physical device, not the simulator):

  1. Install the current debug build on the iPhone 17 Pro Max. Confirm it is
     unlocked, charging, and Location + Health permissions are enabled.
       xcodebuild -project "$PROJECT" -scheme "$SCHEME" \\
         -destination "platform=iOS,name=$DEVICE_MODEL" \\
         -derivedDataPath "$DERIVED_FOCUSED-device" build

  2. Import the full 32,000-row Life Cycle archive once. Wait for the import
     progress state to finish before measuring anything.
  3. Clear Diagnostics, force-quit LifeLog, launch it three times. Record
     first-screen timing each run; the worst must stay within 250 ms once the
     store is established.
  4. On Timeline, scroll top to end and back twice; tap the current-location
     card and one historical card. No interaction may stall past 250 ms.
  5. Return to Timeline from Insights, Activities, Settings, and the Visit
     Editor. Each selection-to-appearance sample must stay within 350 ms.
  6. Open Activities; the background archive summary must finish within
     1,000 ms without blocking navigation.
  7. Open Insights and measure Day (250 ms), Week (500 ms), Month (750 ms),
     and Year (1,500 ms) once each; change date, return to Today, repeat.
  8. Open Settings -> Diagnostics and retain the exported report.
  9. Repeat steps 3-7 after a device restart; compare worst timing per
     operation, not individual samples.

  Optional reachability-only pass on the device (does not prove sensor
  behaviour, only that the UI still renders on hardware):
       xcodebuild -project "$PROJECT" -scheme "$SCHEME" \\
         -destination "platform=iOS,name=$DEVICE_MODEL" \\
         -derivedDataPath "$DERIVED_UI-device" \\
         test -only-testing:LifeLogUITests/AccessibilitySmokeTests

  Never run "xcrun simctl erase" or delete LifeLog's on-device store as part
  of this checklist.
EOF
}

report_version_alignment() {
  local derived="$1" app_path plist yml_marketing yml_build bundle_short bundle_build
  app_path="$(find "$derived/Build/Products" -maxdepth 2 -iname "LifeLog.app" 2>/dev/null | head -1)"
  if [[ -z "$app_path" ]]; then
    warn "Could not find built LifeLog.app under $derived/Build/Products - skipping version-alignment check."
    return
  fi
  plist="$app_path/Info.plist"
  yml_marketing="$(sed -n 's/.*MARKETING_VERSION: *"\([^"]*\)".*/\1/p' "$SPEC" | head -1)"
  yml_build="$(sed -n 's/.*CURRENT_PROJECT_VERSION: *"\([^"]*\)".*/\1/p' "$SPEC" | head -1)"
  bundle_short="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null || echo "?")"
  bundle_build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist" 2>/dev/null || echo "?")"

  log "Version alignment:"
  log "  project.yml MARKETING_VERSION/CURRENT_PROJECT_VERSION: $yml_marketing / $yml_build"
  log "  built app bundle CFBundleShortVersionString/CFBundleVersion: $bundle_short / $bundle_build"
  log "  Settings -> Version reads CFBundleShortVersionString/CFBundleVersion straight from this bundle, so it will show \"$bundle_short ($bundle_build)\" once this build is installed."

  if [[ "$yml_marketing" != "$bundle_short" || "$yml_build" != "$bundle_build" ]]; then
    fail "Version mismatch: project.yml says $yml_marketing/$yml_build but the built bundle says $bundle_short/$bundle_build. Re-run xcodegen and rebuild."
  fi
  log "Version alignment: OK"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <fast|data|ui-smoke|full|device-checklist>

  fast             compile + focused core unit tests (data-tier classes skipped)
  data             schema migrations, backup, resolver, import, performance tests
  ui-smoke         deterministic seeded Timeline/Insights/Activities/Settings checks
  full             every unit test and every UI test
  device-checklist commands + manual checklist for the iPhone 17 Pro Max

Logs and .xcresult bundles are written under:
  $VERIFY_ROOT/<timestamp>/

Override the base directory with LIFELOG_VERIFY_DIR.
See scripts/VERIFY.md for details.
EOF
}

main() {
  local tier="${1:-}"
  [[ -n "$tier" ]] || { usage; exit 1; }

  require_tools
  mkdir -p "$LOG_DIR"
  log "Run directory: $RUN_DIR"

  case "$tier" in
    fast)
      regenerate_and_verify_project
      resolve_simulator_udid
      tier_fast
      ;;
    data)
      regenerate_and_verify_project
      resolve_simulator_udid
      tier_data
      ;;
    ui-smoke)
      regenerate_and_verify_project
      resolve_simulator_udid
      tier_ui_smoke
      ;;
    full)
      regenerate_and_verify_project
      resolve_simulator_udid
      tier_full
      ;;
    device-checklist)
      regenerate_and_verify_project
      tier_device_checklist
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac

  log "Tier \"$tier\" completed successfully."
}

main "$@"
