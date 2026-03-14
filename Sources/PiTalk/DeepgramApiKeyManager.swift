import Foundation

enum DeepgramApiKeySource {
    case processEnvironment
    case userDefaults
    case dotEnv
}

struct DeepgramApiKeyResolution {
    let key: String
    let source: DeepgramApiKeySource
}

enum DeepgramApiKeyBootstrapResult {
    case alreadyConfigured
    case importedFromEnvironment
    case importedFromDotEnv
    case notFound
}

enum DeepgramApiKeyImportResult {
    case imported
    case skippedExisting
    case missingFile
    case keyNotFound
}

enum DeepgramApiKeyManager {
    static let userDefaultsKey = "deepgramApiKey"
    private static let envKeys = ["DEEPGRAM_API_KEY", "DEEPGRAM_TTS_API_KEY"]

    static func resolved() -> DeepgramApiKeyResolution? {
        if let key = keyFromProcessEnvironment() {
            return DeepgramApiKeyResolution(key: key, source: .processEnvironment)
        }

        if let key = keyFromUserDefaults() {
            return DeepgramApiKeyResolution(key: key, source: .userDefaults)
        }

        if let key = keyFromDotEnv() {
            return DeepgramApiKeyResolution(key: key, source: .dotEnv)
        }

        return nil
    }

    static func resolvedKey() -> String? {
        resolved()?.key
    }

    static func bootstrapPersistedKeyIfNeeded() -> DeepgramApiKeyBootstrapResult {
        if keyFromUserDefaults() != nil {
            return .alreadyConfigured
        }

        if let envKey = keyFromProcessEnvironment() {
            UserDefaults.standard.set(envKey, forKey: userDefaultsKey)
            return .importedFromEnvironment
        }

        if let dotEnvKey = keyFromDotEnv() {
            UserDefaults.standard.set(dotEnvKey, forKey: userDefaultsKey)
            return .importedFromDotEnv
        }

        return .notFound
    }

    static func importFromDotEnv(overwriteExisting: Bool = false) -> DeepgramApiKeyImportResult {
        if !overwriteExisting, keyFromUserDefaults() != nil {
            return .skippedExisting
        }

        let dotEnvURL = defaultDotEnvURL()
        guard FileManager.default.fileExists(atPath: dotEnvURL.path) else {
            return .missingFile
        }

        guard let dotEnvKey = keyFromDotEnv() else {
            return .keyNotFound
        }

        UserDefaults.standard.set(dotEnvKey, forKey: userDefaultsKey)
        return .imported
    }

    static func defaultDotEnvURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".env")
    }

    private static func keyFromProcessEnvironment() -> String? {
        for envKey in envKeys {
            if let value = ProcessInfo.processInfo.environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func keyFromUserDefaults() -> String? {
        if let value = UserDefaults.standard.string(forKey: userDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return nil
    }

    private static func keyFromDotEnv() -> String? {
        let dotEnvURL = defaultDotEnvURL()
        guard let content = try? String(contentsOf: dotEnvURL, encoding: .utf8) else {
            return nil
        }

        let values = parseDotEnv(content)
        for envKey in envKeys {
            if let value = values[envKey], !value.isEmpty {
                return value
            }
        }

        return nil
    }

    private static func parseDotEnv(_ content: String) -> [String: String] {
        var result: [String: String] = [:]

        for line in content.split(whereSeparator: \.isNewline) {
            var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            if trimmed.hasPrefix("export ") {
                trimmed = String(trimmed.dropFirst("export ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard let equals = trimmed.firstIndex(of: "=") else { continue }

            let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !key.isEmpty else { continue }

            if value.hasPrefix("\"") && value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                value = value.replacingOccurrences(of: "\\n", with: "\n")
                value = value.replacingOccurrences(of: "\\\"", with: "\"")
            } else if value.hasPrefix("'") && value.hasSuffix("'"), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if let commentIndex = value.firstIndex(of: "#") {
                value = String(value[..<commentIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if !value.isEmpty {
                result[key] = value
            }
        }

        return result
    }
}
