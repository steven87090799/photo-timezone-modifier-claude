import Foundation
import Testing
@testable import TimezoneCore

@Suite(.serialized)
struct ChildProcessRegistryTests {
    @Test func shutdownKillsOnlyOwnedToolsAndPreventsLateLaunch() throws {
        let registry = ChildProcessRegistry()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = ["-e", "$SIG{TERM}=sub{}; $|=1; print \"ready\\n\"; while(1){sleep 60}"]
        child.standardInput = FileHandle.nullDevice
        let ready = Pipe()
        child.standardOutput = ready; child.standardError = FileHandle.nullDevice
        try registry.launch(child)
        #expect(try ready.fileHandleForReading.read(upToCount: 6) == Data("ready\n".utf8))
        #expect(child.isRunning)
        let began = ProcessInfo.processInfo.systemUptime
        registry.shutdown()
        #expect(!child.isRunning)
        #expect(child.terminationStatus == 9)
        #expect(ProcessInfo.processInfo.systemUptime - began < 2)
        let late = Process(); late.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        #expect(throws: CancellationError.self) { try registry.launch(late) }
        registry.finished(child)
        registry.shutdown() // Idempotent.
    }
}
