import Foundation

@MainActor
func runGUIHarnessRoutingSuites() async {
    suite("GUI harness: desktop access is explicit and invalid arguments fail closed") {
        do {
            let selection = try GUIHarnessSelection(arguments: [])
            expect(
                selection.mode == .background && selection.selector == nil,
                "default is the background batch")
            for selector in GUIHarnessSelection.backgroundSelectors {
                let focused = try GUIHarnessSelection(arguments: [selector])
                expect(
                    focused.mode == .background && focused.selector == selector,
                    "background selector remains usable: \(selector)")
            }
            for selector in GUIHarnessSelection.foregroundSelectors {
                for arguments in [
                    [selector], ["--background", selector], ["--dry-run", selector],
                ] {
                    expect(
                        guiHarnessRejects(arguments),
                        "native selector cannot silently take desktop access: \(arguments)")
                }
                let native = try GUIHarnessSelection(arguments: ["--foreground", selector])
                expect(
                    native.mode == .foreground && native.selector == selector,
                    "explicit native selector remains supported: \(selector)")
            }
            for arguments in [
                ["--foregound"], ["--background", "--foreground"], ["--all", "--background"],
                ["--foreground", "--foreground"], ["--view-wiring", "--app-motion"],
                ["--all", "--view-wiring"], ["--minimal"], ["--background", "--typo"],
            ] {
                expect(
                    guiHarnessRejects(arguments),
                    "ambiguous/unknown invocation cannot fall through to all tests: \(arguments)")
            }
            let preview = try GUIHarnessSelection(arguments: ["--foreground", "--dry-run"])
            expect(
                preview.dryRun && preview.mode == .foreground,
                "dry-run describes the requested batch")
            let minimal = try GUIHarnessSelection(arguments: [
                "--foreground", "--gui-baseline-regressions", "--minimal",
            ])
            expect(
                minimal.selector == "--gui-baseline-regressions",
                "existing gallery modifier is preserved")
            let cancelOnly = try GUIHarnessSelection(arguments: [
                "--foreground", "--settings-native-states", "--settings-native-cancel-only",
            ])
            expect(
                cancelOnly.mode == .foreground && cancelOnly.selector == "--settings-native-states",
                "existing native cancellation modifier preserves the focused selector")
        } catch {
            expect(false, "valid harness invocation was rejected: \(error)")
        }
    }

    await suite("GUI harness: the actual batch dispatcher excludes foreground work by default") {
        for (mode, expected) in [
            (GUIHarnessMode.background, ["background start", "background end"]),
            (.foreground, ["foreground"]),
            (.all, ["background start", "background end", "foreground"]),
        ] {
            var calls: [String] = []
            await executeGUIHarnessBatches(
                mode: mode,
                background: {
                    calls.append("background start")
                    await Task.yield()
                    calls.append("background end")
                },
                foreground: { calls.append("foreground") })
            expect(
                calls == expected, "\(mode): batches execute only when selected and never overlap")
        }
    }

    suite("GUI harness: executable preflight cannot fall through into native execution") {
        // SwiftPM can supply a relative argv[0] when using an external scratch directory.
        // Process must receive the resolved URL, not a URL retaining that relative base.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).absoluteURL
        for (arguments, status, message) in [
            (["--dry-run"], Int32(0), "GUI checks: background batch"),
            (["--foreground", "--dry-run"], 0, "GUI checks: foreground batch"),
            (["--all", "--dry-run"], 0, "GUI checks: all batch"),
            (
                [
                    "--foreground", "--settings-native-states", "--settings-native-cancel-only",
                    "--dry-run",
                ], 0, "GUI checks: foreground --settings-native-states"
            ),
            (
                ["--foreground", "--settings-native-cancel-only", "--dry-run"], 2,
                "--settings-native-cancel-only requires --settings-native-states."
            ),
            (
                [
                    "--foreground", "--gui-baseline-regressions", "--settings-native-cancel-only",
                    "--dry-run",
                ], 2, "--settings-native-cancel-only requires --settings-native-states."
            ),
            (
                ["--settings-native-states", "--settings-native-cancel-only", "--dry-run"], 2,
                "Run with --foreground"
            ),
            (
                [
                    "--background", "--settings-native-states", "--settings-native-cancel-only",
                    "--dry-run",
                ], 2, "Run with --foreground"
            ),
            (["--settings-navigation-native-focus"], 2, "Run with --foreground"),
            (["--ai-cue-animation-native"], 2, "Run with --foreground"),
            (["--foregound"], 2, "Unknown test argument"),
        ] {
            let result = runTestProcess(executableURL: executable, arguments: arguments)
            expect(
                result.status == status && result.output.contains(message),
                "CLI preflight \(arguments): \(result.output)")
            expect(
                !result.output.contains("• "), "preflight must exit before any suite is executed")
        }
    }

    suite("GUI harness: every focused entry point has a desktop-access classification") {
        // String-based CLI routing is a cross-file contract, not a compile-time link.
        let main = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("main.swift")
        guard let source = try? String(contentsOf: main, encoding: .utf8),
            let expression = try? NSRegularExpression(
                pattern: #"CommandLine\.arguments\.contains\("(--[^"\n]+)"\)"#)
        else {
            expect(false, "read the executable's actual focused routes"); return
        }
        let routes = Set(
            expression.matches(in: source, range: NSRange(source.startIndex..., in: source))
                .compactMap { match in
                    Range(match.range(at: 1), in: source).map { String(source[$0]) }
                }
        ).subtracting(["--help", "--minimal"])
        expect(
            routes == GUIHarnessSelection.selectors,
            "every route must be classified, and every classified route must exist")
        expect(
            GUIHarnessSelection.backgroundSelectors.isDisjoint(
                with: GUIHarnessSelection.foregroundSelectors),
            "a focused route has one desktop-access owner")
    }
}

private func guiHarnessRejects(_ arguments: [String]) -> Bool {
    do {
        _ = try GUIHarnessSelection(arguments: arguments)
        return false
    } catch { return true }
}
