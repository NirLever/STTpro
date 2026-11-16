import AppKit
import SwiftUI
import UniformTypeIdentifiers
import STTproCore

@MainActor
final class HistoryModel: ObservableObject {
    let store: HistoryStore?
    @Published var records: [TranscriptRecord] = []
    @Published var query = ""
    @Published var selection: Int64?
    @Published var flash: String?
    private var observer: NSObjectProtocol?

    init(store: HistoryStore?) {
        self.store = store
        reload()
        observer = NotificationCenter.default.addObserver(forName: .historyDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    var selected: TranscriptRecord? { records.first { $0.id == selection } }

    func reload() {
        guard let store else { records = []; return }
        let q = query.trimmingCharacters(in: .whitespaces)
        records = q.isEmpty ? store.recent(limit: 500) : store.search(q, limit: 500)
        if let selection, !records.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    func copySelected() {
        guard let r = selected else { return }
        PasteService.copy(r.text)
        show("Copied to clipboard")
    }

    func deleteSelected() {
        guard let r = selected else { return }
        store?.delete(id: r.id)
        reload()
    }

    func export(json: Bool) {
        guard let store else { return }
        let panel = NSSavePanel()
        let stamp = Self.fileStamp.string(from: Date())
        panel.nameFieldStringValue = "STTpro_export_\(stamp).\(json ? "json" : "txt")"
        panel.allowedContentTypes = [json ? .json : .plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let all = store.recent(limit: 10_000)
        do {
            if json {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let items: [[String: Any]] = all.map { r in [
                    "Id": r.id, "Timestamp": iso.string(from: r.timestamp), "Text": r.text,
                    "Language": r.detectedLanguage, "Duration": r.durationSeconds,
                    "ProviderName": r.providerName, "TargetWindowName": r.targetWindowName,
                ] }
                try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys]).write(to: url)
            } else {
                var out = ""
                for r in all {
                    out += "[\(Self.rowStamp.string(from: r.timestamp))] (\(r.detectedLanguage), \(String(format: "%.1f", r.durationSeconds))s)\n"
                    out += r.text + "\n" + String(repeating: "-", count: 60) + "\n\n"
                }
                try out.write(to: url, atomically: true, encoding: .utf8)
            }
            show("Exported \(all.count) transcripts")
        } catch {
            show("Export failed: \(error.localizedDescription)")
        }
    }

    private func show(_ text: String) {
        flash = text
        Task { try? await Task.sleep(for: .seconds(2.5)); if flash == text { flash = nil } }
    }

    static let rowStamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()
    private static let fileStamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"; return f
    }()
}

/// History list (SettingsWindow "History" tab and the separate HistoryWindow).
struct HistoryPage: View {
    @EnvironmentObject var model: HistoryModel
    var showsTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTitle {
                BrandTitle(first: "Transcript", second: " History", size: 21).padding(.bottom, 16)
            }
            HStack(spacing: 8) {
                STTTextField(placeholder: "Search transcripts", text: $model.query, onSubmit: model.reload)
                Button("Search", action: model.reload).sttButton(.primary)
            }
            .padding(.bottom, 12)

            HistoryList()

            HStack(spacing: 6) {
                Button("Copy", action: model.copySelected).sttButton(.primary).disabled(model.selected == nil)
                Button("Delete", action: model.deleteSelected).sttButton(.delete).disabled(model.selected == nil)
                Button("Refresh", action: model.reload).sttButton(.secondary)
                if !showsTitle {
                    Button("Export JSON") { model.export(json: true) }.sttButton(.secondary)
                    Button("Export Text") { model.export(json: false) }.sttButton(.secondary)
                }
                Spacer()
                if let flash = model.flash {
                    Text(flash).font(.system(size: 11)).foregroundStyle(Theme.accentGreen).transition(.opacity)
                }
            }
            .padding(.top, 12)

            if !showsTitle {
                Text("All transcriptions are stored locally on this device and are never sent anywhere.")
                    .hintLabel().italic().padding(.top, 10)
            }
        }
        .padding(.horizontal, showsTitle ? 22 : 20)
        .padding(.top, showsTitle ? 18 : 16)
        .padding(.bottom, showsTitle ? 20 : 16)
        .background(Theme.bgPrimary)
        .tint(Theme.accentBlue)
        .onAppear { model.reload() }
        .animation(.easeOut(duration: 0.2), value: model.flash)
    }
}

private struct HistoryList: View {
    @EnvironmentObject var model: HistoryModel

    var body: some View {
        Group {
            if model.store == nil {
                empty("History unavailable", "The history database couldn't be opened. See ~/Library/Logs/STTpro/sttpro.log.")
            } else if model.records.isEmpty {
                empty(model.query.isEmpty ? "No transcripts yet" : "No matches",
                      model.query.isEmpty ? "Your dictations will appear here." : "Try a different search.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.records) { r in
                            HistoryRow(record: r, selected: model.selection == r.id)
                                .onTapGesture { model.selection = r.id }
                                .onTapGesture(count: 2) { model.selection = r.id; model.copySelected() }
                            Rectangle().fill(Theme.border).frame(height: 1).padding(.horizontal, 14)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bgCard))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "text.bubble").font(.system(size: 28)).foregroundStyle(Theme.textMuted)
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            Text(detail).hintLabel()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HistoryRow: View {
    let record: TranscriptRecord
    let selected: Bool
    @ViewState private var hovering = false
    @ViewState private var showOriginal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(HistoryModel.rowStamp.string(from: record.timestamp)).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                if !record.detectedLanguage.isEmpty { Badge(text: record.detectedLanguage) }
                Text(String(format: "%.1fs", record.durationSeconds)).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                if !record.promptName.isEmpty {
                    Badge(text: record.promptName, color: Theme.accentOrange, background: Theme.badgeOrangeBg)
                }
                Spacer()
                Text(record.targetWindowName).font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: 150, alignment: .trailing)
            }
            Text(record.text)
                .font(.system(size: 13)).foregroundStyle(record.insertionSucceeded ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(selected ? nil : 3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if selected && !record.originalText.isEmpty {
                Button(showOriginal ? "Hide original" : "Show original transcription") { showOriginal.toggle() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accentBlue)
                if showOriginal {
                    Text(record.originalText).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.selectedOverlay : (hovering ? Theme.hoverOverlay : .clear)))
        .overlay(selected ? RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accentBorderSubtle) : nil)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
