import Foundation

/// Resolves short-lived integration hook processes back to the interactive agent
/// that owns them. Codex native hooks run as a new process for every event, so
/// using the hook PID directly makes one CLI session appear as many sessions.
enum AgentProcessResolver {
    struct ProcessRecord: Equatable {
        let pid: Int
        let ppid: Int
        let command: String
    }

    static func canonicalPid(for pid: Int?, sourceApp: String?) -> Int? {
        guard let pid else { return nil }
        let app = sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard app == "codex" || app.hasPrefix("codex-") else { return pid }

        let records = processRecords()
        return canonicalPid(for: pid, sourceApp: app, processes: records)
    }

    static func canonicalPid(
        for pid: Int,
        sourceApp: String?,
        processes: [ProcessRecord]
    ) -> Int {
        let app = sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard app == "codex" || app.hasPrefix("codex-") else { return pid }

        let byPid = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        var current: Int? = pid
        var seen = Set<Int>()

        while let candidate = current, seen.insert(candidate).inserted,
              let process = byPid[candidate] {
            if isCodexProcess(process.command) {
                return candidate
            }
            current = process.ppid > 0 ? process.ppid : nil
        }

        return pid
    }

    private static func isCodexProcess(_ command: String) -> Bool {
        guard let executable = command.split(whereSeparator: { $0.isWhitespace }).first else {
            return false
        }
        let unquoted = executable.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return URL(fileURLWithPath: unquoted).lastPathComponent.lowercased() == "codex"
    }

    private static func processRecords() -> [ProcessRecord] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return output.split(separator: "\n").compactMap { line in
            let fields = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3,
                  let pid = Int(fields[0]),
                  let ppid = Int(fields[1]) else {
                return nil
            }
            return ProcessRecord(pid: pid, ppid: ppid, command: String(fields[2]))
        }
    }
}
