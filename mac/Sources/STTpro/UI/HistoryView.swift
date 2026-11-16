import AppKit
import SwiftUI
import STTproCore

@MainActor
final class HistoryModel: ObservableObject {
    let store: HistoryStore?
    @Published var records: [TranscriptRecord] = []
    @Published var query = "" { didSet { reload() } }
    private var observer: NSObjectProtocol?

    init(store: HistoryStore?) {
        self.store = store
        reload()
        observer = NotificationCenter.default.addObserver(forName: .historyDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        guard let store else { records = []; return }
        let q = query.trimmingCharacters(in: .whitespaces)
        records = q.isEmpty ? store.recent(limit: 500) : store.search(q, limit: 500)
    }

    func delete(_ r: TranscriptRecord) {
        store?.delete(id: r.id)
        reload()
    }

    func deleteAll() {
        store?.deleteAll()
        reload()
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: HistoryModel
    @ViewState private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search history", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                Button("Show in Finder") {
                    if let url = model.store?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button("Clear…", role: .destructive) { confirmClear = true }
                    .disabled(model.records.isEmpty)
            }
            .padding(12)
            Divider()

            if model.store == nil {
                ContentUnavailableView("History unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text("The history database couldn't be opened. See ~/Library/Logs/STTpro/sttpro.log."))
            } else if model.records.isEmpty {
                ContentUnavailableView(model.query.isEmpty ? "No transcripts yet" : "No matches",
                                       systemImage: "text.bubble",
                                       description: Text(model.query.isEmpty ? "Your dictations will appear here." : ""))
            } else {
                List(model.records) { r in HistoryRow(record: r, onDelete: { model.delete(r) }) }
                    .listStyle(.inset)
            }
        }
        .onAppear { model.reload() }
        .confirmationDialog("Delete all transcripts?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { model.deleteAll() }
        } message: {
            Text("This permanently removes every transcript from this Mac's history.")
        }
    }
}

private struct HistoryRow: View {
    let record: TranscriptRecord
    let onDelete: () -> Void
    @ViewState private var showOriginal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(record.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                if !record.targetWindowName.isEmpty {
                    Text("· \(record.targetWindowName)").font(.caption).foregroundStyle(.secondary)
                }
                if !record.detectedLanguage.isEmpty {
                    Text(record.detectedLanguage).font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }
                if !record.promptName.isEmpty {
                    Label(record.promptName, systemImage: "sparkles").font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                Spacer()
                Button { PasteService.copy(record.text) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy")
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Delete")
            }
            Text(record.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !record.originalText.isEmpty {
                DisclosureGroup("Original transcription", isExpanded: $showOriginal) {
                    Text(record.originalText).textSelection(.enabled).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}
