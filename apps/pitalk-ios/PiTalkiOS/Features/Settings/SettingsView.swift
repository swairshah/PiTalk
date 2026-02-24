import SwiftUI

struct RemoteSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("pitalk.appearance") private var appearance: AppAppearance = .system

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    connectionSection
                    appearanceSection
                    statusSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connection")
                .font(.headline)

            TextField("Host (tailnet DNS or IP)", text: $store.host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            TextField("Port", text: $store.port)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)

            SecureField("Token (optional in no-auth dev mode)", text: $store.token)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Button("Connect") {
                    store.connect()
                }
                .buttonStyle(.borderedProminent)

                Button("Disconnect") {
                    store.disconnect()
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

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

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Status")
                .font(.headline)

            HStack {
                Text("State")
                Spacer()
                Text(stateLabel)
                    .foregroundStyle(stateColor)
            }

            HStack {
                Text("Last event seq")
                Spacer()
                Text("\(store.socket.lastSeq)")
                    .font(.system(.body, design: .monospaced))
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
