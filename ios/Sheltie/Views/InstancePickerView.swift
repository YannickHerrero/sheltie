import SwiftUI

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
                    if !store.profiles.isEmpty {
                        instancesSection
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

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel(pendingPairing == nil ? "ADD A MAC" : "CONFIRM ON THIS IPAD")
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
                Text("Use the HTTPS URL exposed by Tailscale Serve. Pairing also verifies a key generated on this iPad.")
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
