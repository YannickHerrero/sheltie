import SwiftUI
import UserNotifications

private struct SheltieSettingsView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        Form {
            Section {
                Toggle("Agent completed", isOn: Binding(
                    get: { store.doneNotificationsEnabled },
                    set: store.setDoneNotificationsEnabled
                ))
                Toggle("Agent blocked", isOn: Binding(
                    get: { store.blockedNotificationsEnabled },
                    set: store.setBlockedNotificationsEnabled
                ))
            } header: {
                Text("Push Notifications")
            } footer: {
                Text("The Mac sends generic alerts through Apple Push Notification service. Project names, paths, prompts, and terminal output are never included.")
            }

            Section("Delivery Status") {
                LabeledContent("System permission", value: authorizationLabel)
                LabeledContent("Mac provider", value: providerLabel)
                if store.notificationAuthorizationStatus == .denied {
                    Button("Open System Notification Settings") {
                        store.openSystemNotificationSettings()
                    }
                }
                if let message = store.notificationErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(SheltieTheme.danger)
                }
            }

            Section("Provider Usage") {
                if let usage = store.snapshot?.usageMeters.first {
                    LabeledContent(usage.label, value: "\(Int((usage.remainingFraction * 100).rounded()))% left")
                    if Date().timeIntervalSince1970 * 1_000 - Double(usage.observedAtMillis) > 5 * 60_000 {
                        Label("Last reading is stale", systemImage: "clock.badge.exclamationmark")
                            .foregroundStyle(SheltieTheme.warning)
                    }
                } else {
                    LabeledContent("Codex", value: "Unavailable")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.refreshNotificationAuthorization() }
    }

    private var authorizationLabel: String {
        switch store.notificationAuthorizationStatus {
        case .notDetermined: "Not requested"
        case .denied: "Denied"
        case .authorized: "Allowed"
        case .provisional: "Provisional"
        case .ephemeral: "Temporary"
        @unknown default: "Unknown"
        }
    }

    private var providerLabel: String {
        if store.snapshot?.bridge.capabilities.contains("notifications.apns") != true {
            return "Bridge not configured"
        }
        return store.notificationProviderConfigured ? "Ready" : "Waiting for device token"
    }
}

struct InstancePickerView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = ""
    @State private var pendingPairing: PendingPairing?
    @State private var pairingCode = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    settingsSection
                    if !store.profiles.isEmpty {
                        instancesSection
                    }
                    if (store.snapshot?.sessions.count ?? 0) > 1 {
                        sessionsSection
                    }
                    pairingSection
                }
                .padding(24)
            }
            .background(SheltieTheme.background)
            .navigationTitle("Herdr Instances")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("SETTINGS")
            NavigationLink {
                SheltieSettingsView(store: store)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(SheltieTheme.muted)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Settings")
                            .font(SheltieTheme.body(14, weight: .semibold))
                            .foregroundStyle(SheltieTheme.foreground)
                        Text("Notifications and provider status")
                            .font(SheltieTheme.mono(10))
                            .foregroundStyle(SheltieTheme.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SheltieTheme.muted)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(SheltieTheme.surface.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(SheltieTheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var instancesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("REGISTERED MACS")
            ForEach(store.profiles) { profile in
                Button {
                    store.selectInstance(profile.id)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(profile.id == store.selectedProfileID && store.phase.isConnected ? SheltieTheme.success : SheltieTheme.muted)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.displayName)
                                .font(SheltieTheme.body(14, weight: .semibold))
                                .foregroundStyle(SheltieTheme.foreground)
                            Text(profile.baseURL.absoluteString)
                                .font(SheltieTheme.mono(10))
                                .foregroundStyle(SheltieTheme.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if profile.id == store.selectedProfileID {
                            Text("CURRENT")
                                .font(SheltieTheme.mono(9, weight: .bold))
                                .foregroundStyle(SheltieTheme.success)
                                .padding(.horizontal, 9)
                                .frame(height: 26)
                                .background(Capsule().fill(SheltieTheme.success.opacity(0.1)))
                                .overlay(Capsule().stroke(SheltieTheme.success.opacity(0.4), lineWidth: 1))
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(SheltieTheme.surface.opacity(0.5)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(SheltieTheme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Remove", role: .destructive) { store.removeInstance(profile.id) }
                }
            }
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("HERDR SESSIONS")
            ForEach(store.snapshot?.sessions ?? []) { session in
                Button {
                    store.selectSession(session.id)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(session.reachable ? SheltieTheme.success : SheltieTheme.danger)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.name)
                                .font(SheltieTheme.body(14, weight: .semibold))
                            Text(session.isDefault ? "default session" : "named session")
                                .font(SheltieTheme.mono(10))
                                .foregroundStyle(SheltieTheme.muted)
                        }
                        Spacer()
                        if session.id == store.selectedSessionID {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(SheltieTheme.success)
                        }
                    }
                    .foregroundStyle(SheltieTheme.foreground)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(SheltieTheme.surface.opacity(0.5)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(SheltieTheme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!session.reachable)
            }
        }
    }

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel(pendingPairing == nil ? "ADD A MAC" : "CONFIRM ON THIS DEVICE")
            if let pendingPairing {
                Text("Enter the six-digit code printed by the Sheltie bridge on \(pendingPairing.baseURL.host ?? "the Mac").")
                    .font(SheltieTheme.body(13))
                    .foregroundStyle(SheltieTheme.muted)
                TextField("000000", text: $pairingCode)
                    .font(SheltieTheme.mono(24, weight: .bold))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .textContentType(.oneTimeCode)
                    .padding(.horizontal, 14)
                    .frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 8).fill(SheltieTheme.surface.opacity(0.5)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(SheltieTheme.border, lineWidth: 1))
                    .onChange(of: pairingCode) { _, value in
                        pairingCode = String(value.filter(\.isNumber).prefix(6))
                    }
                primaryButton("Complete Pairing") {
                    complete(pendingPairing)
                }
                .disabled(pairingCode.count != 6 || isWorking)
                Button("Start over") {
                    self.pendingPairing = nil
                    pairingCode = ""
                    errorMessage = nil
                }
                .font(SheltieTheme.body(13))
                .foregroundStyle(SheltieTheme.muted)
            } else {
                Text("Use the HTTPS URL exposed by Tailscale Serve. Pairing also verifies a key generated on this device.")
                    .font(SheltieTheme.body(13))
                    .foregroundStyle(SheltieTheme.muted)
                TextField("https://mac-name.ts.net/sheltie", text: $baseURL)
                    .font(SheltieTheme.mono(12))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(.horizontal, 14)
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 8).fill(SheltieTheme.surface.opacity(0.5)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(SheltieTheme.border, lineWidth: 1))
                primaryButton("Request Pairing") { begin() }
                    .disabled(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
            }
            if isWorking {
                ProgressView().tint(SheltieTheme.accent)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(SheltieTheme.body(12))
                    .foregroundStyle(SheltieTheme.danger)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(SheltieTheme.surface.opacity(0.44)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(SheltieTheme.border, lineWidth: 1))
    }

    private func sectionLabel(_ value: String) -> some View {
        Text(value)
            .font(SheltieTheme.mono(10, weight: .bold))
            .tracking(1.1)
            .foregroundStyle(SheltieTheme.muted)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(SheltieTheme.body(14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 8).fill(SheltieTheme.accent))
        }
        .buttonStyle(.plain)
    }

    private func begin() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                pendingPairing = try await store.beginPairing(baseURLString: baseURL)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func complete(_ pairing: PendingPairing) {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await store.completePairing(pairing, code: pairingCode)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isWorking = false
            }
        }
    }
}
