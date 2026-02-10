//
// PrivateServerSettingsView.swift
// bitchat
//
// Settings UI for managing private Nostr relay servers.
//

import SwiftUI

struct PrivateServerSettingsView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var persistence = PrivateServerPersistenceService.shared
    @Environment(\.colorScheme) var colorScheme

    @State private var showAddServer = false
    @State private var serverToEdit: PrivateServerConfig?

    private var backgroundColor: Color { colorScheme == .dark ? .black : .white }
    private var textColor: Color { colorScheme == .dark ? .green : Color(red: 0, green: 0.5, blue: 0) }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                headerView

                // Description
                Text("Add your own Nostr-compatible relay servers for private messaging. These have higher priority than public relays.")
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(textColor.opacity(0.7))
                    .padding(.horizontal)

                // Server list
                if persistence.servers.isEmpty {
                    emptyStateView
                } else {
                    serverListView
                }

                Spacer()

                // Add server button
                addServerButton
            }
            .background(backgroundColor)
            #if os(iOS)
            .navigationBarHidden(true)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 500)
        #endif
        .sheet(isPresented: $showAddServer) {
            AddEditServerView(isPresented: $showAddServer, serverToEdit: nil)
        }
        .sheet(item: $serverToEdit) { server in
            AddEditServerView(isPresented: Binding(
                get: { serverToEdit != nil },
                set: { if !$0 { serverToEdit = nil } }
            ), serverToEdit: server)
        }
    }

    private var headerView: some View {
        HStack {
            Button(action: { isPresented = false }) {
                Image(systemName: "xmark")
                    .font(.bitchatSystem(size: 14, weight: .semibold))
                    .foregroundColor(textColor)
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Private Servers")
                .font(.bitchatSystem(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(textColor)

            Spacer()

            // Placeholder for symmetry
            Image(systemName: "xmark")
                .font(.bitchatSystem(size: 14, weight: .semibold))
                .foregroundColor(.clear)
        }
        .padding()
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "server.rack")
                .font(.system(size: 48))
                .foregroundColor(textColor.opacity(0.5))

            Text("No private servers configured")
                .font(.bitchatSystem(size: 14, design: .monospaced))
                .foregroundColor(textColor.opacity(0.7))

            Text("Tap + to add your own relay server")
                .font(.bitchatSystem(size: 12, design: .monospaced))
                .foregroundColor(textColor.opacity(0.5))

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var serverListView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(persistence.servers) { server in
                    ServerRowView(
                        server: server,
                        textColor: textColor,
                        onToggle: { toggleServer(server) },
                        onEdit: { serverToEdit = server },
                        onDelete: { deleteServer(server) }
                    )
                }
            }
            .padding(.horizontal)
        }
    }

    private var addServerButton: some View {
        Button(action: { showAddServer = true }) {
            HStack {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
                Text("Add Server")
                    .font(.bitchatSystem(size: 14, weight: .medium, design: .monospaced))
            }
            .foregroundColor(textColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(textColor.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.bottom)
    }

    private func toggleServer(_ server: PrivateServerConfig) {
        persistence.toggleServerEnabled(server.id)
    }

    private func deleteServer(_ server: PrivateServerConfig) {
        TransportManager.shared.removePrivateServer(server.id)
    }
}

// MARK: - Server Row View

struct ServerRowView: View {
    let server: PrivateServerConfig
    let textColor: Color
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) var colorScheme

    private var backgroundColor: Color { colorScheme == .dark ? .black : .white }

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(server.isEnabled ? Color.green : Color.gray)
                .frame(width: 10, height: 10)

            // Server info
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.bitchatSystem(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(textColor)

                Text(server.url)
                    .font(.bitchatSystem(size: 11, design: .monospaced))
                    .foregroundColor(textColor.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer()

            // Toggle
            Toggle("", isOn: Binding(
                get: { server.isEnabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle(tint: textColor))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.03))
        )
        .contextMenu {
            Button(action: onEdit) {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .onTapGesture {
            onEdit()
        }
    }
}

// MARK: - Add/Edit Server View

struct AddEditServerView: View {
    @Binding var isPresented: Bool
    let serverToEdit: PrivateServerConfig?

    @State private var name: String = ""
    @State private var url: String = ""
    @State private var authToken: String = ""
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var isTesting: Bool = false
    @State private var testResult: TestResult?

    @Environment(\.colorScheme) var colorScheme

    private var backgroundColor: Color { colorScheme == .dark ? .black : .white }
    private var textColor: Color { colorScheme == .dark ? .green : Color(red: 0, green: 0.5, blue: 0) }

    private var isEditing: Bool { serverToEdit != nil }
    private var isValidInput: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !url.trimmingCharacters(in: .whitespaces).isEmpty &&
        isValidURL
    }

    private var isValidURL: Bool {
        guard let parsed = URL(string: url) else { return false }
        let scheme = parsed.scheme?.lowercased()
        return scheme == "wss" || scheme == "ws"
    }

    enum TestResult {
        case success
        case failure(String)
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Button(action: { isPresented = false }) {
                        Text("Cancel")
                            .font(.bitchatSystem(size: 14, design: .monospaced))
                            .foregroundColor(textColor)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text(isEditing ? "Edit Server" : "Add Server")
                        .font(.bitchatSystem(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(textColor)

                    Spacer()

                    Button(action: save) {
                        Text("Save")
                            .font(.bitchatSystem(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(isValidInput ? textColor : textColor.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isValidInput)
                }
                .padding()

                // Form
                VStack(alignment: .leading, spacing: 16) {
                    // Name field
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name")
                            .font(.bitchatSystem(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(textColor.opacity(0.7))

                        TextField("e.g., Work Server", text: $name)
                            .font(.bitchatSystem(size: 14, design: .monospaced))
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(textColor.opacity(0.3), lineWidth: 1)
                            )
                    }

                    // URL field
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WebSocket URL")
                            .font(.bitchatSystem(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(textColor.opacity(0.7))

                        TextField("wss://relay.example.com", text: $url)
                            .font(.bitchatSystem(size: 14, design: .monospaced))
                            .textFieldStyle(.plain)
                            #if os(iOS)
                            .autocapitalization(.none)
                            #endif
                            .disableAutocorrection(true)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(isValidURL || url.isEmpty ? textColor.opacity(0.3) : Color.red.opacity(0.5), lineWidth: 1)
                            )

                        if !url.isEmpty && !isValidURL {
                            Text("URL must start with wss:// or ws://")
                                .font(.bitchatSystem(size: 10, design: .monospaced))
                                .foregroundColor(.red.opacity(0.8))
                        }
                    }

                    // Auth token field (optional)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Auth Token (optional)")
                            .font(.bitchatSystem(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(textColor.opacity(0.7))

                        SecureField("For NIP-42 authentication", text: $authToken)
                            .font(.bitchatSystem(size: 14, design: .monospaced))
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(textColor.opacity(0.3), lineWidth: 1)
                            )
                    }

                    // Test connection button
                    Button(action: testConnection) {
                        HStack {
                            if isTesting {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 12))
                            }
                            Text("Test Connection")
                                .font(.bitchatSystem(size: 13, design: .monospaced))
                        }
                        .foregroundColor(isValidURL ? textColor : textColor.opacity(0.3))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(textColor.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!isValidURL || isTesting)

                    // Test result
                    if let result = testResult {
                        HStack(spacing: 6) {
                            switch result {
                            case .success:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Connection successful")
                                    .foregroundColor(.green)
                            case .failure(let message):
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                Text(message)
                                    .foregroundColor(.red)
                            }
                        }
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                    }
                }
                .padding(.horizontal)

                Spacer()
            }
            .background(backgroundColor)
            #if os(iOS)
            .navigationBarHidden(true)
            #endif
            .onAppear {
                if let server = serverToEdit {
                    name = server.name
                    url = server.url
                    authToken = server.authToken ?? ""
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 350, minHeight: 400)
        #endif
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        let trimmedToken = authToken.trimmingCharacters(in: .whitespaces)

        if isEditing, let existing = serverToEdit {
            var updated = existing
            updated.name = trimmedName
            updated.url = trimmedURL
            updated.authToken = trimmedToken.isEmpty ? nil : trimmedToken
            TransportManager.shared.updatePrivateServer(updated)
        } else {
            let config = PrivateServerConfig(
                name: trimmedName,
                url: trimmedURL,
                authToken: trimmedToken.isEmpty ? nil : trimmedToken
            )
            TransportManager.shared.addPrivateServer(config)
        }

        isPresented = false
    }

    private func testConnection() {
        guard let testURL = URL(string: url) else { return }

        isTesting = true
        testResult = nil

        // Create a test WebSocket connection
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config)
        let task = session.webSocketTask(with: testURL)

        task.resume()

        // Wait for connection or timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if task.state == .running {
                testResult = .success
            } else {
                testResult = .failure("Connection failed")
            }
            task.cancel()
            session.invalidateAndCancel()
            isTesting = false
        }
    }
}

// MARK: - Preview

#if DEBUG
struct PrivateServerSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        PrivateServerSettingsView(isPresented: .constant(true))
    }
}
#endif
