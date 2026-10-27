#!/usr/bin/env python3
"""Compile the unchanged XCTest case bodies with small standalone assertions.

Apple Command Line Tools on some installations omit both XCTest and Testing.
The canonical suite remains ActivityStoreTests.swift; no test bodies are copied.
The transformation fails if an unsupported assertion is introduced.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / "Tests/KeyTrailCoreTests/ActivityStoreTests.swift").read_text()
supported = {"XCTAssertEqual", "XCTAssertTrue", "XCTAssertFalse", "XCTAssertThrowsError"}
assertions = set(re.findall(r"\b(XCTAssert\w+)", source))
if assertions - supported:
    raise SystemExit(f"Unsupported standalone assertion: {assertions - supported}")
tests = re.findall(r"func (test\w+)\(", source)
if not tests:
    raise SystemExit("No regression cases discovered")
source = (source.replace("import XCTest", "import Foundation")
          .replace("@testable import KeyTrailCore", "")
          .replace("final class ActivityStoreTests: XCTestCase", "final class ActivityStoreTests")
          .replace("override func", "func"))
helpers = r'''
func XCTAssertEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T,
                                 file: StaticString = #filePath, line: UInt = #line) {
    let a = try! actual(), e = try! expected()
    precondition(a == e, "Assertion at \(file):\(line): \(a) != \(e)")
}
func XCTAssertTrue(_ actual: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    precondition(try! actual(), "Assertion at \(file):\(line)")
}
func XCTAssertFalse(_ actual: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    precondition(try! !actual(), "Assertion at \(file):\(line)")
}
func XCTAssertThrowsError<T>(_ actual: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try actual(); preconditionFailure("Expected throw at \(file):\(line)") } catch {}
}
'''
runner = "\n@main struct StandaloneCoreTests { static func main() throws {\n"
for test in tests:
    runner += ("do { let suite = ActivityStoreTests(); try suite.setUpWithError(); "
               "defer { try? suite.tearDownWithError() }; "
               f'try suite.{test}(); print("PASS {test}") }}\n')
runner += f'print("Passed {len(tests)} standalone core checks (same XCTest case bodies)")\n}} }}\n'
with tempfile.TemporaryDirectory(prefix="keytrail-core-tests-") as temporary:
    harness = Path(temporary) / "Standalone.swift"
    binary = Path(temporary) / "core-tests"
    harness.write_text(helpers + source + runner)
    subprocess.run(["swiftc", "-I", str(root / "Sources/CSQLite"),
                    str(root / "Sources/KeyTrailCore/Models.swift"),
                    str(root / "Sources/KeyTrailCore/ActivityStore.swift"),
                    str(harness), "-o", str(binary)], check=True, cwd=root)
    subprocess.run([str(binary)], check=True, cwd=root)
