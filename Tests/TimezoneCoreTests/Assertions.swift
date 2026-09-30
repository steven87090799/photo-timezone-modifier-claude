import Foundation
import Testing
@testable import TimezoneCore

// Small migration helpers: all failures are real Swift Testing issues.
private func location(_ file: StaticString, _ line: UInt) -> SourceLocation {
    SourceLocation(fileID: String(describing: file), filePath: String(describing: file), line: Int(line), column: 1)
}
func recordFailure(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    Issue.record(Comment(rawValue: message), sourceLocation: location(file, line))
}
func requireValue<T>(_ value: @autoclosure () throws -> T?, _ message: String = "Required value is nil",
                     file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value = try value() else {
        recordFailure(message, file: file, line: line)
        throw PhotoError(message)
    }
    return value
}
func expectEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                              _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        let lhs = try a(), rhs = try b()
        #expect(lhs == rhs, Comment(rawValue: message), sourceLocation: location(file, line))
    } catch { Issue.record(error, sourceLocation: location(file, line)) }
}
func expectNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                 _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        let lhs = try a(), rhs = try b()
        #expect(lhs != rhs, Comment(rawValue: message), sourceLocation: location(file, line))
    } catch { Issue.record(error, sourceLocation: location(file, line)) }
}
func expectTrue(_ value: @autoclosure () throws -> Bool, _ message: String = "",
                file: StaticString = #filePath, line: UInt = #line) {
    do { #expect(try value(), Comment(rawValue: message), sourceLocation: location(file, line)) }
    catch { Issue.record(error, sourceLocation: location(file, line)) }
}
func expectFalse(_ value: @autoclosure () throws -> Bool, _ message: String = "",
                 file: StaticString = #filePath, line: UInt = #line) {
    do { #expect(try !value(), Comment(rawValue: message), sourceLocation: location(file, line)) }
    catch { Issue.record(error, sourceLocation: location(file, line)) }
}
