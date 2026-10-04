#!/usr/bin/env bash
# A Foundation-only fallback gate when the GUI's SwiftUI macro toolchain is unavailable.
# This is separate evidence, never a replacement for the full GUI executable harness.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --package-path gui --target ClaudioGUICore
navigation_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/claudio-navigation-tests.XXXXXX")"
trap 'rm -rf "$navigation_test_dir"' EXIT
python3 - "$navigation_test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('gui/Tests/ClaudioGUICoreTests/main.swift').read_text()
start = source.index('var totalChecks = 0')
end = source.index('// A separate process', start)
Path(sys.argv[1]).write_text('import Foundation\nimport ClaudioCore\nimport ClaudioGUICore\n' + source[start:end] + '''
runEventNoticeModelSuites()
await runSessionNavigationSuites()
runHostSessionNavigationSuites()
runTmuxNavigationSuites()
await runIDENavigationSocketSuites()
await runNavigationReviewRegressionSuites()
print("Navigation core: \\(totalChecks - failures)/\\(totalChecks) passed")
exit(failures == 0 ? 0 : 1)
''')
PY
swiftc -swift-version 6 -package-name claudio-gui -enable-testing -emit-module -emit-object \
  -whole-module-optimization -module-name ClaudioGUIComponents \
  -emit-module-path "$navigation_test_dir/ClaudioGUIComponents.swiftmodule" \
  -I gui/.build/out/Products/Debug \
  -Xcc -fmodule-map-file=gui/.build/out/Intermediates.noindex/GeneratedModuleMaps/ClaudioVersionC.modulemap \
  gui/Sources/ClaudioGUIComponents/{NavigationCommand,NavigationFocusGuard,EventNoticeNavigationIngress,IDENavigationSocket,IDENavigationBridge,HostSessionNavigationAdapter,TmuxNavigationAdapter,SourceApplicationAdapter,SourceApplicationEnvironment,SourceApplicationDescriptor}.swift \
  -o "$navigation_test_dir/ClaudioGUIComponents.o"
swiftc -swift-version 6 -package-name claudio-gui -I "$navigation_test_dir" -I gui/.build/out/Products/Debug \
  -Xcc -fmodule-map-file=gui/.build/out/Intermediates.noindex/GeneratedModuleMaps/ClaudioVersionC.modulemap \
  "$navigation_test_dir/main.swift" \
  gui/Tests/ClaudioGUICoreTests/EventNoticeModelSuite.swift \
  gui/Tests/ClaudioGUICoreTests/SessionNavigationSuite.swift \
  gui/Tests/ClaudioGUICoreTests/HostSessionNavigationSuite.swift \
  gui/Tests/ClaudioGUICoreTests/TmuxNavigationSuite.swift \
  gui/Tests/ClaudioGUICoreTests/IDENavigationSocketSuite.swift \
  gui/Tests/ClaudioGUICoreTests/NavigationReviewRegressionSuite.swift \
  "$navigation_test_dir/ClaudioGUIComponents.o" \
  gui/.build/out/Products/Debug/ClaudioCore.o \
  gui/.build/out/Products/Debug/ClaudioGUICore.o \
  gui/.build/out/Products/Debug/ClaudioLocalization.o \
  gui/.build/out/Products/Debug/ClaudioVersionC.o \
  -framework Security -o "$navigation_test_dir/tests"
"$navigation_test_dir/tests"
swiftc -swift-version 6 -package-name claudio-gui -typecheck -I gui/.build/out/Products/Debug \
  -Xcc -fmodule-map-file=gui/.build/out/Intermediates.noindex/GeneratedModuleMaps/ClaudioVersionC.modulemap \
  gui/Sources/ClaudioGUIComponents/{NavigationCommand,NavigationFocusGuard,EventNoticeNavigationIngress,IDENavigationSocket,IDENavigationBridge,HostSessionNavigationAdapter,TmuxNavigationAdapter,SourceApplicationAdapter,SourceApplicationEnvironment,SourceApplicationDescriptor}.swift

# Compile the production composition against the same navigation module, including DEBUG wiring.
swiftc -swift-version 6 -package-name claudio-gui -D DEBUG -typecheck \
  -I "$navigation_test_dir" -I gui/.build/out/Products/Debug \
  -Xcc -fmodule-map-file=gui/.build/out/Intermediates.noindex/GeneratedModuleMaps/ClaudioVersionC.modulemap \
  gui/Sources/ClaudioGUI/{EventNoticeRuntime,CodexQuestionObservationSession}.swift
