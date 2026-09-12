import AppKit
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct SharedSharesView: View {
    @Bindable var model: ShareManagementViewModel
    let onOpenLibrary: () -> Void
    @State private var stopping: SharePublication?
    @State private var changingExpiry: SharePublication?
    @State private var expiration = Date()
    @State private var showingRecovery = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shared pages").font(DesignSystem.Typography.pageTitle)
                    Text("Separate, expiring text snapshots. Local edits never publish automatically.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button("Recovery…") { showingRecovery = true }.parakeetAction(.secondary)
                Button("Refresh") { Task { await model.refresh() } }.parakeetAction(.secondary).disabled(model.isBusy)
            }
            if let error = model.errorMessage { Text(error).foregroundStyle(DesignSystem.Colors.errorRed) }
            if model.publications.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text("No shared pages on this Mac").font(DesignSystem.Typography.sectionTitle)
                    Text("Open a transcript and choose Share to preview exactly what you want to publish. If you shared from another installation, restore management with your recovery code.")
                        .foregroundStyle(.secondary)
                    Button("Open Library", action: onOpenLibrary).parakeetAction(.primary)
                }.padding(.vertical, 40)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(model.publications) { share in
                            row(share)
                            Divider()
                        }
                    }.padding(.vertical, 8)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DesignSystem.Colors.background)
        .task { await model.refresh() }
        .sheet(isPresented: $showingRecovery) { ShareRecoveryView(model: model) }
        .sheet(item: $changingExpiry) { share in
            VStack(alignment: .leading, spacing: 20) {
                Text("Change expiration").font(DesignSystem.Typography.pageTitle)
                DatePicker("Available until", selection: $expiration, displayedComponents: [.date, .hourAndMinute])
                Text("Original lifetime limit: \(share.maxExpiresAt.formatted(date: .abbreviated, time: .standard)). Stopped or expired links cannot be extended.")
                    .foregroundStyle(.secondary)
                if let error = model.errorMessage { Text(error).foregroundStyle(DesignSystem.Colors.errorRed) }
                HStack {
                    Button("Cancel") { changingExpiry = nil }.parakeetAction(.secondary)
                    Spacer()
                    Button("Save expiration") {
                        Task {
                            await model.changeExpiry(share, to: expiration)
                            if model.errorMessage == nil { changingExpiry = nil }
                        }
                    }.parakeetAction(.primary).disabled(model.isBusy)
                }
            }.padding(24).frame(width: 480)
        }
        .confirmationDialog("Stop sharing permanently?", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } })) {
            Button("Stop sharing permanently", role: .destructive) {
                if let share = stopping { Task { await model.stop(share) } }
                stopping = nil
            }
            Button("Cancel", role: .cancel) { stopping = nil }
        } message: { Text(SharePresentationCopy.stopConfirmation) }
    }

    private func row(_ share: SharePublication) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.titles[share.id] ?? "Shared page \(share.remoteShareId.prefix(6))")
                .font(DesignSystem.Typography.sectionTitle)
            Text(model.status(for: share)).foregroundStyle(.secondary)
            Text("Expires \(share.expiresAt.formatted(date: .abbreviated, time: .standard)) · Revision \(share.contentRevision)")
                .font(.caption).foregroundStyle(.secondary)
            if share.isDetached { Text("The local source was removed. This record keeps its remote stop manageable.").font(.caption) }
            if let link = model.links[share.id] { ShareLinkActions(link: link) }
            HStack {
                if model.canUpdate(share) {
                    Button("Update shared page…") { Task { await model.prepareDraft(for: share, updating: true) } }.parakeetAction(.secondary)
                }
                if model.canManage(share) {
                    Button("Expiration…") { expiration = share.expiresAt; changingExpiry = share }.parakeetAction(.secondary)
                }
                if !share.isTerminal && !model.credentialSuperseded && !model.pending[share.id, default: []].contains(.delete) {
                    Button("Stop sharing…", role: .destructive) { stopping = share }.parakeetAction(.destructive).disabled(model.isBusy)
                }
                if share.isTerminal && model.availableSourceIDs.contains(share.id) {
                    Button("Create a new link…") { Task { await model.prepareDraft(for: share, updating: false) } }.parakeetAction(.secondary).disabled(model.isBusy)
                }
                if share.deletionState == .complete && model.pending[share.id, default: []].isEmpty {
                    Button("Remove record from this Mac") { Task { await model.forget(share) } }.parakeetAction(.secondary).disabled(model.isBusy)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ShareRecoveryView: View {
    @Bindable var model: ShareManagementViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var proof = ""
    @State private var importedCode = ""
    @State private var confirmRemoval = false
    @State private var confirmFresh = false
    @State private var confirmImport = false

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Sharing recovery").font(DesignSystem.Typography.pageTitle)
                Spacer()
                Button("Done") { dismiss() }.parakeetAction(.secondary).disabled(model.isBusy)
            }
            Text(SharePresentationCopy.recovery).foregroundStyle(.secondary)
            if let code = model.recoveryCode {
                Text("Save your recovery code").font(.headline)
                Text(code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button("Copy recovery code") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
                    }.parakeetAction(.secondary)
                    Button("I saved it") { Task { await model.acknowledgeRecoverySaved() } }.parakeetAction(.primary).disabled(model.isBusy)
                }
            } else {
                Button("Set up a recovery code") { Task { await model.setUpRecovery() } }.parakeetAction(.primary).disabled(model.isBusy)
                Text("Already have a saved code? Keep it. To replace or remove it, enter that code below.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            DisclosureGroup("Replace or remove my current code") {
                VStack(alignment: .leading, spacing: 12) {
                    SecureField("Current recovery code", text: $proof)
                    HStack {
                        Button("Replace code") { Task { await model.replaceRecovery(proof: proof); if model.errorMessage == nil { proof = "" } } }.parakeetAction(.secondary)
                        Button("Remove recovery…", role: .destructive) { confirmRemoval = true }.parakeetAction(.destructive)
                    }.disabled(model.isBusy || proof.isEmpty)
                }.padding(.top, 10)
            }
            DisclosureGroup("Restore management from a recovery code") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Restoring invalidates the previous installation’s management credential and the imported code. Earlier links become management-only. If this Mac manages a different owner, all its links must be stopped and deletion completed first.")
                        .font(.callout).foregroundStyle(.secondary)
                    SecureField("Recovery code to restore", text: $importedCode)
                    Button("Restore management…") { confirmImport = true }.parakeetAction(.secondary).disabled(model.isBusy || importedCode.isEmpty)
                }.padding(.top, 10)
            }
            DisclosureGroup("I lost my configured recovery code") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("You can keep managing links from this Mac. Recovery cannot be reset without its code. Stop all outstanding links and wait for deletion; then you can start with a new anonymous owner.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Start fresh after all links are deleted…") { confirmFresh = true }.parakeetAction(.secondary).disabled(model.isBusy)
                }.padding(.top, 10)
            }
            if let message = model.recoveryMessage { Text(message).font(.callout) }
            if let error = model.errorMessage { Text(error).foregroundStyle(DesignSystem.Colors.errorRed) }
            HStack {
                if model.isBusy { ProgressView().controlSize(.small) }
                Button("Reconcile pending confirmation") { Task { await model.refresh() } }.parakeetAction(.secondary).disabled(model.isBusy)
            }
        }
        .padding(24)
        }
        .frame(width: 600, height: 640)
        .interactiveDismissDisabled(model.isBusy)
        .task { await model.refresh() }
        .confirmationDialog("Remove recovery?", isPresented: $confirmRemoval) {
            Button("Remove recovery", role: .destructive) { Task { await model.removeRecovery(proof: proof); if model.errorMessage == nil { proof = "" } } }
        } message: { Text("If this Mac loses its sharing credentials, you will no longer be able to stop existing links early.") }
        .confirmationDialog("Restore management on this Mac?", isPresented: $confirmImport) {
            Button("Restore management") { Task { await model.importRecovery(code: importedCode); if model.errorMessage == nil { importedCode = "" } } }
        } message: { Text("The imported code and previous installation’s management credential will stop working. Existing local authority is preserved if recovery fails.") }
        .confirmationDialog("Start a new anonymous owner?", isPresented: $confirmFresh) {
            Button("Check and start fresh", role: .destructive) { Task { await model.startFreshOwner() } }
        } message: { Text("This checks the service before discarding the old credential. It refuses until every old link is terminal and encrypted-copy deletion is complete.") }
    }
}
