import SwiftUI

/** History (everything used) and Saved for later: open, play, save, edit, remove (with Undo). (LibraryScreen.kt) */
struct LibraryView: View {
    let library: Library
    let onOpen: (Library.Entry) -> Void
    let onPlay: (Library.Entry) -> Void

    @State private var tab = 0
    @State private var editing: Library.Entry?
    @State private var removed: (entry: Library.Entry, tab: Int)?
    @State private var undoTask: Task<Void, Never>?

    private var history: [Library.Entry] { library.entries.filter(\.inHistory) }
    private var saved: [Library.Entry] { library.entries.filter(\.saved) }

    var body: some View {
        let shown = tab == 0 ? history : saved
        List {
            Section {
                Picker("Show", selection: $tab) {
                    Text("History").tag(0)
                    Text("Saved for later").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if shown.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: tab == 0 ? "clock.arrow.circlepath" : "bookmark").font(.largeTitle).foregroundStyle(.secondary)
                    Text(tab == 0 ? "Titles and links you share, paste or play show up here." : "Tap the bookmark on a title to watch it later.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
                .listRowBackground(Color.clear)
            }
            ForEach(shown) { e in
                EntryRow(entry: e, onOpen: { onOpen(e) }, onPlay: { onPlay(e) },
                         onToggleSaved: { library.setSaved(e.title, meta: nil, saved: !e.saved) })
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { remove(e) } label: { Label("Remove", systemImage: "trash") }
                    }
                    .contextMenu {
                        Button { editing = e } label: { Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive) { remove(e) } label: {
                            Label(tab == 0 ? "Remove from history" : "Remove from saved", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .background(Color(.systemGroupedBackground))
        .scrollContentBackground(.hidden)
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Text("\(history.count) in history · \(saved.count) saved").font(.caption).foregroundStyle(.secondary)
            }
        }
        .overlay(alignment: .bottom) {
            if let r = removed {
                HStack {
                    Text(r.tab == 0 ? "Removed “\(r.entry.name)” from history" : "Removed “\(r.entry.name)” from saved")
                        .font(.subheadline).lineLimit(2)
                    Spacer()
                    Button("Undo") {
                        library.restore(r.entry)
                        removed = nil
                    }
                    .bold()
                }
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: removed?.entry)
        .sheet(item: $editing) { e in
            EditEntryView(entry: e) { library.edit($0); editing = nil }
        }
    }

    private func remove(_ e: Library.Entry) {
        if tab == 0 { library.removeFromHistory(e.imdbId) } else { library.setSaved(e.title, meta: nil, saved: false) }
        removed = (e, tab)
        undoTask?.cancel()
        undoTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { removed = nil }
        }
    }
}

/** An entry changed by hand: its name, movie or series, season and episode. */
struct EditEntryView: View {
    @State var entry: Library.Entry
    let onSave: (Library.Entry) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $entry.name)
                if entry.link == nil {
                    Picker("Type", selection: $entry.series) {
                        Text("Movie").tag(false)
                        Text("Series").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if entry.series {
                        Stepper("Season \(entry.season)", value: $entry.season, in: 1...999)
                        Stepper("Episode \(entry.episode)", value: $entry.episode, in: 1...9999)
                    }
                }
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(entry) } }
            }
        }
        .presentationDetents([.medium])
    }
}
