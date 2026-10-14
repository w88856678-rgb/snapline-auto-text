// Minimal assertions for the fallback runner on CLT installations without XCTest.
// The normal SwiftPM tests continue to use Apple's XCTest unchanged.
import Foundation

class XCTestCase {}
nonisolated(unsafe) var standaloneCheckCount = 0
nonisolated(unsafe) var standaloneFailureCount = 0

private func check(_ passes: Bool, _ message: String, file: StaticString, line: UInt) {
    standaloneCheckCount += 1
    if !passes {
        standaloneFailureCount += 1
        print("FAIL \(file):\(line): \(message)")
    }
}

func XCTFail(_ message: String = "Unexpected failure", file: StaticString = #fileID, line: UInt = #line) {
    check(false, message, file: file, line: line)
}
func XCTAssertTrue(_ value: @autoclosure () -> Bool, _ message: String = "Expected true", file: StaticString = #fileID, line: UInt = #line) {
    check(value(), message, file: file, line: line)
}
func XCTAssertFalse(_ value: @autoclosure () -> Bool, _ message: String = "Expected false", file: StaticString = #fileID, line: UInt = #line) {
    check(!value(), message, file: file, line: line)
}
func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () -> T, _ rhs: @autoclosure () -> T, _ message: String = "Expected equal values", file: StaticString = #fileID, line: UInt = #line) {
    check(lhs() == rhs(), message, file: file, line: line)
}
func XCTAssertNotEqual<T: Equatable>(_ lhs: @autoclosure () -> T, _ rhs: @autoclosure () -> T, _ message: String = "Expected different values", file: StaticString = #fileID, line: UInt = #line) {
    check(lhs() != rhs(), message, file: file, line: line)
}
func XCTAssertNil<T>(_ value: @autoclosure () -> T?, _ message: String = "Expected nil", file: StaticString = #fileID, line: UInt = #line) {
    check(value() == nil, message, file: file, line: line)
}
func XCTAssertNotNil<T>(_ value: @autoclosure () -> T?, _ message: String = "Expected non-nil", file: StaticString = #fileID, line: UInt = #line) {
    check(value() != nil, message, file: file, line: line)
}
func XCTAssertGreaterThan<T: Comparable>(_ lhs: @autoclosure () -> T, _ rhs: @autoclosure () -> T, _ message: String = "Expected a greater value", file: StaticString = #fileID, line: UInt = #line) {
    check(lhs() > rhs(), message, file: file, line: line)
}
struct StandaloneUnwrapError: Error {}
func XCTUnwrap<T>(_ value: @autoclosure () throws -> T?, _ message: String = "Expected non-nil", file: StaticString = #fileID, line: UInt = #line) throws -> T {
    let result = try value()
    check(result != nil, message, file: file, line: line)
    guard let result else { throw StandaloneUnwrapError() }
    return result
}
