import Foundation

class TestSuite {}
var checkFailures: [String] = []
var checkCount = 0
private var checkpointFailures = 0
func checkpoint(_ name: String) {
    checkCount += 1
    print((checkFailures.count == checkpointFailures ? "PASS " : "FAIL ") + name)
    checkpointFailures = checkFailures.count
}
func runCheck(_ name: String, _ work: () throws -> Void) {
    do { try work() } catch { checkFailures.append(name + ": " + error.localizedDescription) }
    checkpoint(name)
}
func failure(_ reason: String, file: String, line: Int) {
    checkFailures.append("\((file as NSString).lastPathComponent):\(line): \(reason)")
}
func expectEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: T, file: String = #file, line: Int = #line) {
    do { if try actual() != expected { failure("values differ", file: file, line: line) } } catch { failure("expression threw", file: file, line: line) }
}
func expectNotEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: T, file: String = #file, line: Int = #line) {
    do { if try actual() == expected { failure("values unexpectedly equal", file: file, line: line) } } catch { failure("expression threw", file: file, line: line) }
}
func expectTrue(_ actual: @autoclosure () throws -> Bool, file: String = #file, line: Int = #line) {
    do { if try !actual() { failure("expected true", file: file, line: line) } } catch { failure("expression threw", file: file, line: line) }
}
func expectFalse(_ actual: @autoclosure () throws -> Bool, file: String = #file, line: Int = #line) {
    do { if try actual() { failure("expected false", file: file, line: line) } } catch { failure("expression threw", file: file, line: line) }
}
func expectNil<T>(_ actual: @autoclosure () throws -> T?, file: String = #file, line: Int = #line) {
    do { if try actual() != nil { failure("expected nil", file: file, line: line) } } catch { failure("expression threw", file: file, line: line) }
}
func expectThrows<T>(_ operation: @autoclosure () throws -> T, file: String = #file, line: Int = #line) {
    do { _ = try operation(); failure("expected error", file: file, line: line) } catch {}
}
func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw KeyDockError.message("required test value missing") }; return value
}
