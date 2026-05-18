import SwiftUI
import Foundation

struct PostProcessingRule: Identifiable, Codable, Equatable {
    let id: UUID
    var find: String
    var replace: String
    var isEnabled: Bool
    var isBuiltIn: Bool

    init(
        id: UUID = UUID(),
        find: String,
        replace: String,
        isEnabled: Bool = true,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.find = find
        self.replace = replace
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
    }
}

enum StaticPostProcessingRules {
    /// Built-in normalization rules applied before text is sent to the TTS provider.
    /// Add more static app-wide rules here. They run top-to-bottom before custom user rules.
    static let rules: [PostProcessingRule] = [
        PostProcessingRule(find: "\u{2018}", replace: "'", isBuiltIn: true), // ‘ -> '
        PostProcessingRule(find: "\u{2019}", replace: "'", isBuiltIn: true), // ’ -> '
        PostProcessingRule(find: "\u{201C}", replace: "\"", isBuiltIn: true), // “ -> "
        PostProcessingRule(find: "\u{201D}", replace: "\"", isBuiltIn: true), // ” -> "
    ]
}

final class PostProcessingRuleStore: ObservableObject {
    static let shared = PostProcessingRuleStore()

    @Published private(set) var customRules: [PostProcessingRule] = []

    static var builtInRules: [PostProcessingRule] { StaticPostProcessingRules.rules }

    private let lock = NSLock()
    private let rulesFileURL: URL
    private var customRulesStorage: [PostProcessingRule] = []

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let piTalkDir = appSupport.appendingPathComponent("PiTalk", isDirectory: true)
        rulesFileURL = piTalkDir.appendingPathComponent("post-processing-rules.json")

        let loaded = Self.loadCustomRules(from: rulesFileURL)
        customRulesStorage = loaded
        customRules = loaded
    }

    func apply(to text: String) -> String {
        let rules = enabledRulesSnapshot()
        guard !rules.isEmpty else { return text }

        var processed = text
        for rule in rules {
            guard !rule.find.isEmpty else { continue }
            processed = processed.replacingOccurrences(of: rule.find, with: rule.replace)
        }
        return processed
    }

    func addCustomRule(find: String = "", replace: String = "") {
        var rule = PostProcessingRule(find: find, replace: replace, isEnabled: true, isBuiltIn: false)
        // Defensive: callers should not create custom rules flagged as built-in.
        rule.isBuiltIn = false
        let snapshot = mutateCustomRules { rules in
            rules.append(rule)
        }
        publishAndPersist(snapshot)
    }

    func removeCustomRule(id: UUID) {
        let snapshot = mutateCustomRules { rules in
            rules.removeAll { $0.id == id }
        }
        publishAndPersist(snapshot)
    }

    func updateCustomRule(id: UUID, find: String? = nil, replace: String? = nil, isEnabled: Bool? = nil) {
        let snapshot = mutateCustomRules { rules in
            guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
            if let find { rules[index].find = find }
            if let replace { rules[index].replace = replace }
            if let isEnabled { rules[index].isEnabled = isEnabled }
            rules[index].isBuiltIn = false
        }
        publishAndPersist(snapshot)
    }

    func resetCustomRules() {
        let snapshot = mutateCustomRules { rules in
            rules.removeAll()
        }
        publishAndPersist(snapshot)
    }

    private func enabledRulesSnapshot() -> [PostProcessingRule] {
        lock.lock()
        let custom = customRulesStorage
        lock.unlock()

        return Self.builtInRules.filter { $0.isEnabled && !$0.find.isEmpty }
            + custom.filter { $0.isEnabled && !$0.find.isEmpty }
    }

    private func mutateCustomRules(_ mutate: (inout [PostProcessingRule]) -> Void) -> [PostProcessingRule] {
        lock.lock()
        mutate(&customRulesStorage)
        let snapshot = customRulesStorage
        lock.unlock()
        return snapshot
    }

    private func publishAndPersist(_ snapshot: [PostProcessingRule]) {
        if Thread.isMainThread {
            customRules = snapshot
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.customRules = snapshot
            }
        }
        persist(snapshot)
    }

    private static func loadCustomRules(from url: URL) -> [PostProcessingRule] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([PostProcessingRule].self, from: data)
            return decoded.map { rule in
                PostProcessingRule(
                    id: rule.id,
                    find: rule.find,
                    replace: rule.replace,
                    isEnabled: rule.isEnabled,
                    isBuiltIn: false
                )
            }
        } catch {
            print("PiTalk: Failed to load post-processing rules: \(error)")
            return []
        }
    }

    private func persist(_ rules: [PostProcessingRule]) {
        do {
            let directory = rulesFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let customOnly = rules.map { rule in
                PostProcessingRule(
                    id: rule.id,
                    find: rule.find,
                    replace: rule.replace,
                    isEnabled: rule.isEnabled,
                    isBuiltIn: false
                )
            }
            let data = try JSONEncoder().encode(customOnly)
            try data.write(to: rulesFileURL, options: [.atomic])
        } catch {
            print("PiTalk: Failed to persist post-processing rules: \(error)")
        }
    }
}

struct PostProcessingTabView: View {
    @StateObject private var store = PostProcessingRuleStore.shared
    @State private var previewText = "PiTalk said: “It’s ready.”"

    private var processedPreview: String {
        store.apply(to: previewText)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsSectionHeader(title: "Postprocessing")

                VStack(alignment: .leading, spacing: 8) {
                    Text("Find/replace rules run before text is sent to the speech provider. Built-in normalization runs first, then your custom rules run top-to-bottom.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 10)

                SettingsSectionHeader(title: "Built-in Rules")

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Self.builtInRules) { rule in
                        ruleReadOnlyRow(rule)
                    }
                }
                .padding(.vertical, 10)

                SettingsSectionHeader(title: "Custom Rules")

                VStack(alignment: .leading, spacing: 10) {
                    if store.customRules.isEmpty {
                        Text("No custom rules yet. Add one below to replace text before speech.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(store.customRules) { rule in
                            customRuleRow(rule)
                        }
                    }

                    HStack(spacing: 8) {
                        Button {
                            store.addCustomRule()
                        } label: {
                            Label("Add Rule", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if !store.customRules.isEmpty {
                            Button("Clear Custom Rules") {
                                store.resetCustomRules()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.vertical, 10)

                SettingsSectionHeader(title: "Preview")

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Text to preview", text: $previewText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...4)
                        .padding(8)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )

                    HStack(alignment: .top, spacing: 8) {
                        Text("Output")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 52, alignment: .leading)
                        Text(processedPreview.isEmpty ? " " : processedPreview)
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                }
                .padding(.vertical, 10)

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private static var builtInRules: [PostProcessingRule] {
        PostProcessingRuleStore.builtInRules
    }

    private func ruleReadOnlyRow(_ rule: PostProcessingRule) -> some View {
        HStack(spacing: 8) {
            ruleToken(rule.find)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundColor(.secondary)
            ruleToken(rule.replace)
            Spacer()
            Text("Built-in")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(5)
        }
    }

    private func customRuleRow(_ rule: PostProcessingRule) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { currentRule(rule.id)?.isEnabled ?? rule.isEnabled },
                set: { store.updateCustomRule(id: rule.id, isEnabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            TextField("Find", text: Binding(
                get: { currentRule(rule.id)?.find ?? rule.find },
                set: { store.updateCustomRule(id: rule.id, find: $0) }
            ))
            .textFieldStyle(.plain)
            .padding(6)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )

            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("Replace", text: Binding(
                get: { currentRule(rule.id)?.replace ?? rule.replace },
                set: { store.updateCustomRule(id: rule.id, replace: $0) }
            ))
            .textFieldStyle(.plain)
            .padding(6)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )

            Button(role: .destructive) {
                store.removeCustomRule(id: rule.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func currentRule(_ id: UUID) -> PostProcessingRule? {
        store.customRules.first { $0.id == id }
    }

    private func ruleToken(_ text: String) -> some View {
        Text(text.isEmpty ? "empty" : text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
    }
}
