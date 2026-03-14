import SwiftUI

struct RemoteSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("pitalk.appearance") private var appearance: AppAppearance = .system
    @State private var showAddProfile = false
    @State private var editingProfile: ServerProfile?

    var body: some View {
        NavigationStack {
            ZStack {
                GradientBackground()

                ScrollView {
                    VStack(spacing: 14) {
                        profilesSection
                        appearanceSection
                        statusSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 16)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showAddProfile) {
                ProfileEditorSheet(
                    profile: ServerProfile(name: "", host: "", port: "18082", token: ""),
                    isNew: true,
                    onSave: { profile in
                        store.addProfile(profile)
                    }
                )
            }
            .sheet(item: $editingProfile) { profile in
                ProfileEditorSheet(
                    profile: profile,
                    isNew: false,
                    onSave: { updated in
                        store.updateProfile(updated)
                    }
                )
            }
        }
    }

    // MARK: - Profiles

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Servers")
                    .font(.headline)
                Spacer()
                Button {
                    showAddProfile = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(PT.accent)
                        .frame(width: 32, height: 32)
                        .modifier(GlassCircleModifier())
                }
                .buttonStyle(.plain)
            }

            if store.profiles.isEmpty {
                EmptyStateView(
                    icon: "server.rack",
                    title: "No servers configured",
                    subtitle: "Add a server to get started"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                VStack(spacing: 6) {
                    ForEach(store.profiles) { profile in
                        profileRow(profile)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .modifier(GlassRectModifier(cornerRadius: 16))
    }

    private func profileRow(_ profile: ServerProfile) -> some View {
        let isActive = store.activeProfileId == profile.id
        let isConnected = isActive && store.socket.connectionState == .connected

        return HStack(spacing: 10) {
            if isConnected {
                PulsingDot(color: .green)
            } else {
                Circle()
                    .fill(isActive ? PT.orange : PT.textMuted.opacity(0.3))
                    .frame(width: 8, height: 8)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(profile.host):\(profile.port)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(PT.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if isActive {
                Button {
                    store.disconnect()
                    store.activeProfileId = nil
                } label: {
                    Text("Disconnect")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PT.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .modifier(GlassCapsuleModifier(tint: PT.red.opacity(0.15)))
            } else {
                Button {
                    store.connectToProfile(profile)
                } label: {
                    Text("Connect")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PT.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .modifier(GlassCapsuleModifier(tint: PT.accent.opacity(0.15)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .modifier(GlassRectModifier(cornerRadius: 12))
        .contextMenu {
            Button {
                editingProfile = profile
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive) {
                store.deleteProfile(profile)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .onTapGesture {
            if !isActive {
                store.connectToProfile(profile)
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Appearance")
                .font(.headline)

            Picker("Theme", selection: $appearance) {
                ForEach(AppAppearance.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .modifier(GlassRectModifier(cornerRadius: 16))
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection")
                .font(.headline)

            statusRow(label: "State", value: stateLabel, valueColor: stateColor)

            if let profile = store.activeProfile {
                statusRow(label: "Server", value: profile.displayName)
            }

            statusRow(label: "Last event seq", value: "\(store.socket.lastSeq)", mono: true)

            Toggle(isOn: Binding(
                get: { store.remoteAudioStreamingRequested },
                set: { enabled in
                    store.setRemoteAudioStreaming(enabled: enabled)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stream voice audio to phone")
                        .font(.subheadline)
                    Text("Off by default. When off, server sends no audio chunks.")
                        .font(.caption2)
                        .foregroundStyle(PT.textSecondary)
                }
            }
            .disabled(store.socket.connectionState != .connected)
            .tint(PT.accent)

            if store.remoteAudioStreamingRequested {
                statusRow(
                    label: "Remote audio stream",
                    value: store.socket.audioStreamEnabled ? "Active" : "Paused",
                    valueColor: store.socket.audioStreamEnabled ? .green : .secondary
                )
            }

            if store.socket.audioPlaybackActive {
                HStack {
                    Text("Remote audio")
                        .font(.subheadline)
                    Spacer()
                    HStack(spacing: 4) {
                        PulsingDot(color: .green)
                        Text("Playing")
                            .font(.subheadline)
                            .foregroundStyle(PT.green)
                    }
                }
            }

            if let err = store.socket.lastError, !err.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(PT.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(GlassRectModifier(cornerRadius: 8, tint: PT.red.opacity(0.15)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .modifier(GlassRectModifier(cornerRadius: 16))
    }

    private func statusRow(
        label: String,
        value: String,
        valueColor: Color = .secondary,
        mono: Bool = false
    ) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(mono ? .system(.subheadline, design: .monospaced) : .subheadline)
                .foregroundStyle(valueColor)
        }
    }

    private var stateLabel: String {
        switch store.socket.connectionState {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        case .failed: return "Failed"
        }
    }

    private var stateColor: Color {
        switch store.socket.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .idle, .failed: return .red
        }
    }
}

// MARK: - Profile Editor Sheet

private struct ProfileEditorSheet: View {
    @State var profile: ServerProfile
    let isNew: Bool
    let onSave: (ServerProfile) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                GradientBackground()

                ScrollView {
                    VStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 12) {
                            editorField(label: "Server Name", placeholder: "e.g. M4 MacBook, Intel Mac", text: $profile.name, capitalize: true)
                            editorField(label: "Host", placeholder: "Tailscale IP or hostname", text: $profile.host, keyboard: .URL)
                            editorField(label: "Port", placeholder: "18082", text: $profile.port, keyboard: .numberPad)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Token")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(PT.textSecondary)
                                SecureField("Optional for no-auth dev mode", text: $profile.token)
                                    .font(.subheadline)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .modifier(GlassRectModifier(cornerRadius: 12))
                            }
                        }
                        .padding(14)
                        .modifier(GlassRectModifier(cornerRadius: 16))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                }
            }
            .navigationTitle(isNew ? "Add Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(profile)
                        dismiss()
                    }
                    .disabled(profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func editorField(
        label: String,
        placeholder: String,
        text: Binding<String>,
        capitalize: Bool = false,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(PT.textSecondary)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(capitalize ? .words : .never)
                .autocorrectionDisabled(!capitalize)
                .keyboardType(keyboard)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .modifier(GlassRectModifier(cornerRadius: 12))
        }
    }
}
