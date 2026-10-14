#!/usr/bin/env python3
"""Run the same test methods without XCTest on a Command Line Tools-only Mac.

First build the app in Debug using `swift build`. Pass --build-root .build-tests
to reuse the Debug app objects left by `swift test` if XCTest is unavailable.
This runner links the real app objects, excluding its main entry point, and only
replaces XCTest assertions. It neither runs the app nor changes its sources.
"""
import argparse
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-root", default=".build")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    build_root = root / args.build_root
    arch = platform.machine()
    object_dir = build_root / "out/Intermediates.noindex/Snapline.build/Debug/Snapline-p.build/Objects-normal" / arch
    objects = sorted(path for path in object_dir.glob("*.o") if path.name != "main.o")
    if not objects:
        raise SystemExit("No Debug app objects found; run swift build first.")
    products = build_root / "out/Products/Debug"
    # Some SwiftPM build plans keep the importable module beside its objects.
    module_path = products if (products / "Snapline.swiftmodule").exists() else object_dir
    sdk = os.environ.get("SDKROOT") or subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()

    with tempfile.TemporaryDirectory(prefix="SnaplineStandaloneTests-") as directory:
        scratch = Path(directory)
        sources = [Path(__file__).with_name("Support.swift")]
        methods = []
        for original in sorted((root / "Tests/SnaplineTests").glob("*.swift")):
            content = original.read_text().replace("import XCTest\n", "")
            target = scratch / original.name
            target.write_text(content)
            sources.append(target)
            match = re.search(r"final class (\w+): XCTestCase", content)
            if not match:
                continue
            for method in re.finditer(r"func (test\w+)\(\)([^\{]*)\{", content):
                name, modifiers = method.groups()
                prefix = ("try " if "throws" in modifiers else "") + ("await " if "async" in modifiers else "")
                methods.append((f"{match.group(1)}.{name}", f"{prefix}{match.group(1)}().{name}()", "throws" in modifiers))

        runner = ["import Foundation", "@main struct StandaloneRunner {", "@MainActor static func main() async {"]
        for name, invocation, throws in methods:
            runner.append("do {")
            runner.append("let failuresBefore = standaloneFailureCount")
            runner.append(invocation)
            runner.append(f'print("\\(standaloneFailureCount == failuresBefore ? "PASS" : "FAIL") {name}")')
            if throws:
                runner.append(f'}} catch {{ XCTFail("{name} threw: \\(error)") }}')
            else:
                runner.append("}")
        runner.extend([
            f'print("Standalone result: {len(methods)} tests, \\(standaloneCheckCount) checks, \\(standaloneFailureCount) failures")',
            "exit(standaloneFailureCount == 0 ? 0 : 1)", "}", "}",
        ])
        runner_path = scratch / "Runner.swift"
        runner_path.write_text("\n".join(runner) + "\n")
        sources.append(runner_path)
        executable = scratch / "SnaplineStandaloneTests"
        command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-target", f"{arch}-apple-macos14.0", "-sdk", sdk,
                   "-I", str(module_path), "-module-cache-path", str(scratch / "ModuleCache"),
                   *map(str, sources), *map(str, objects), "-o", str(executable)]
        subprocess.run(command, check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    main()
