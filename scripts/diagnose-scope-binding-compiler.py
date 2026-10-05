#!/usr/bin/env python3
"""Temporary CI probe for Swift's actor-isolation reabstraction crash."""

from pathlib import Path
import os
import subprocess
import tempfile


cases = {
    "method": "return Binding(get: { scope }, set: select)",
    "typed_closure": """
        let setter: @isolated(any) @Sendable (Scope) -> Void = {
            @MainActor value in select(value)
        }
        return Binding(get: { scope }, set: setter)
    """,
    "typed_method": """
        let setter: @isolated(any) @Sendable (Scope) -> Void = select
        return Binding(get: { scope }, set: setter)
    """,
    "generic": "return actorBinding(get: { scope }, set: select)",
    "native_callback": """
        let setter: @MainActor (Scope) -> Void = select
        return setter
    """,
}

with tempfile.TemporaryDirectory(prefix="claudio-scope-compiler-") as directory:
    root = Path(directory)
    sdk = os.environ.get("SDKROOT") or subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
    ).strip()
    for name, body in cases.items():
        result_type = "@MainActor (Scope) -> Void" if name == "native_callback" else "Binding<Scope>"
        source = """
import Foundation
import SwiftUI

enum Scope: Hashable, Sendable { case global, workspace(UUID) }

@MainActor
struct Fixture {
    let scope: Scope
    let onSelect: (Scope) -> Void
    func select(_ scope: Scope) { onSelect(scope) }
""" + "    var selection: " + result_type + " {\n" + body + "\n    }\n}\n"
        if name == "generic":
            source += """
@MainActor
func actorBinding<Value>(
    get: @escaping @MainActor () -> Value,
    set: @escaping @MainActor (Value) -> Void
) -> Binding<Value> {
    Binding(get: { get() }, set: { set($0) })
}
"""
        fixture = root / (name + ".swift")
        fixture.write_text(source)
        result = subprocess.run(
            ["swiftc", "-swift-version", "6", "-Onone", "-target", "arm64-apple-macosx12.0",
             "-sdk", sdk, "-c", str(fixture), "-o", str(root / (name + ".o"))],
            capture_output=True, text=True
        )
        print(f"PROBE {name}: exit={result.returncode}", flush=True)
        for line in result.stderr.splitlines():
            if any(signal in line for signal in ["error:", "SmallVector", "While emitting", "Swift version"]):
                print(line, flush=True)
