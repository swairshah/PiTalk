import SwiftUI

struct RemoteSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("pitalk.appearance") private var appearance: AppAppearance = .system
    @State private var showAddProfile = false
    @State private var editingProfile: ServerProfile?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    profilesSection
                    appearanceSection
                    statusSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
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
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }

            if store.profiles.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "server.rack")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("No servers configured")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("Add a server to get started")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
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
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func profileRow(_ profile: ServerProfile) -> some View {
        let isActive = store.activeProfileId == profile.id
        let isConnected = isActive && store.socket.connectionState == .connected

        return HStack(spacing: 10) {
            Circle()
                .fill(isConnected ? Color.green : (isActive ? Color.orange : Color.gray.opacity(0.3)))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(profile.host):\(profile.port)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if isActive {
                Button {
                    store.disconnect()
                    store.activeProfileId = nil
                } label: {
                    Text("Disconnect")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            } else {
                Button {
                    store.connectToProfile(profile)
                } label: {
                    Text("Connect")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
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
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connection")
                .font(.headline)

            HStack {
                Text("State")
                Spacer()
                Text(stateLabel)
                    .foregroundStyle(stateColor)
            }

            if let profile = store.activeProfile {
                HStack {
                    Text("Server")
                    Spacer()
                    Text(profile.displayName)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Last event seq")
                Spacer()
                Text("\(store.socket.lastSeq)")
                    .font(.system(.body, design: .monospaced))
            }

            Toggle(isOn: Binding(
                get: { store.remoteAudioStreamingRequested },
                set: { enabled in
                    store.setRemoteAudioStreaming(enabled: enabled)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stream voice audio to phone")
                    Text("Off by default. When off, server sends no audio chunks.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(store.socket.connectionState != .connected)

            if store.remoteAudioStreamingRequested {
                HStack {
                    Text("Remote audio stream")
                    Spacer()
                    Text(store.socket.audioStreamEnabled ? "Active" : "Paused")
                        .foregroundStyle(store.socket.audioStreamEnabled ? .green : .secondary)
                }
            }

            if store.socket.audioPlaybackActive {
                HStack {
                    Text("Remote audio")
                    Spacer()
                    Text("Playing")
                        .foregroundStyle(.green)
                }
            }

            if let err = store.socket.lastError, !err.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
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
            ScrollView {
                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Server Name")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("e.g. M4 MacBook, Intel Mac", text: $profile.name)
                            .textInputAutocapitalization(.words)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

                        Text("Host")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("Tailscale IP or hostname", text: $profile.host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

                        Text("Port")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("18082", text: $profile.port)
                            .keyboardType(.numberPad)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

                        Text("Token")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        SecureField("Optional for no-auth dev mode", text: $profile.token)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
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
                }
            }
        }
    }
}
