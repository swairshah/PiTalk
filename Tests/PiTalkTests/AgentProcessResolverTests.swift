import XCTest
@testable import PiTalk

final class AgentProcessResolverTests: XCTestCase {
    func testCodexHookPidResolvesToNativeCodexAncestor() {
        let processes = [
            AgentProcessResolver.ProcessRecord(pid: 100, ppid: 1, command: "node /Users/test/.bun/bin/codex"),
            AgentProcessResolver.ProcessRecord(pid: 101, ppid: 100, command: "/Users/test/vendor/bin/codex"),
            AgentProcessResolver.ProcessRecord(pid: 200, ppid: 101, command: "/bin/sh -c node hook.js"),
            AgentProcessResolver.ProcessRecord(pid: 201, ppid: 200, command: "node hook.js"),
        ]

        XCTAssertEqual(
            AgentProcessResolver.canonicalPid(for: 201, sourceApp: "codex", processes: processes),
            101
        )
    }

    func testNonCodexSourcesKeepOriginalPid() {
        let processes = [
            AgentProcessResolver.ProcessRecord(pid: 101, ppid: 1, command: "/usr/local/bin/codex"),
            AgentProcessResolver.ProcessRecord(pid: 201, ppid: 101, command: "node hook.js"),
        ]

        XCTAssertEqual(
            AgentProcessResolver.canonicalPid(for: 201, sourceApp: "pi", processes: processes),
            201
        )
    }

    func testCodexSourceFallsBackWhenNoCodexAncestorExists() {
        let processes = [
            AgentProcessResolver.ProcessRecord(pid: 201, ppid: 1, command: "node observer.js"),
        ]

        XCTAssertEqual(
            AgentProcessResolver.canonicalPid(for: 201, sourceApp: "codex", processes: processes),
            201
        )
    }
}
