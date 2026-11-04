import SwiftUI
import QuickLook

// MARK: - Go to path

struct GoToSheet: View {
    @EnvironmentObject var lang: LanguageManager
    @ObservedObject var model: FilesModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var recents: [String] =
        UserDefaults.standard.stringArray(forKey: "fs.recents") ?? []

    var body: some View {
        NavigationView {
            Form {
                Section(lang("go.to.path")) {
                    TextField("/var/mobile/…", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                        .onSubmit { submit() }
                    Button(lang("go")) { submit() }
                }
                if !model.favorites.isEmpty {
                    Section(lang("favorites")) {
                        ForEach(model.favorites, id: \.self) { fav in
                            Button {
                                model.go(to: fav)
                                dismiss()
                            } label: {
                                Text(fav).font(.callout.monospaced())
                            }
                        }
                    }
                }
                if !recents.isEmpty {
                    Section(lang("recent")) {
                        ForEach(recents, id: \.self) { recent in
                            Button {
                                model.go(to: recent)
                                dismiss()
                            } label: {
                                Text(recent).font(.callout.monospaced())
                            }
                        }
                    }
                }
            }
            .bileCanvas()
            .navigationTitle(lang("go.to.path"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lang("cancel")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { text = model.path }
    }

    private func submit() {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var list = recents.filter { $0 != clean }
        list.insert(clean, at: 0)
        if list.count > 10 { list.removeLast(list.count - 10) }
        UserDefaults.standard.set(list, forKey: "fs.recents")
        model.go(to: clean)
        dismiss()
    }
}

// MARK: - File info

struct FileInfoView: View {
    @EnvironmentObject var lang: LanguageManager
    let path: String
    @ObservedObject var model: FilesModel
    @Environment(\.dismiss) private var dismiss

    @State private var attrs: LocalFS.Attrs? = nil
    @State private var folderSize: Int64? = nil
    @State private var calculating = false
    @State private var permText = ""

    var body: some View {
        NavigationView {
            Form {
                if let a = attrs {
                    Section {
                        HStack(spacing: 12) {
                            FileGlyph(path: path, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text((path as NSString).lastPathComponent).font(.headline)
                                Text(path)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    Section(lang("info")) {
                        row(lang("type"), a.isDir ? lang("folder") : (a.isLink ? "symlink" : "file"))
                        if !a.isDir {
                            row(lang("size"), FileEntry.prettySize(a.size))
                        }
                        row(lang("permissions"), a.permissionsString)
                        if let owner = a.owner { row("owner", owner) }
                        if let group = a.group { row("group", group) }
                        if let created = a.created {
                            row("created", created.formatted(date: .abbreviated, time: .shortened))
                        }
                        row("modified", a.modified.formatted(date: .abbreviated, time: .shortened))
                        if let target = a.linkTarget {
                            row("→ target", target)
                        }
                    }
                    if a.isDir && !a.isLink {
                        Section {
                            HStack {
                                if calculating {
                                    ProgressView()
                                    Text(lang("calculating")).foregroundStyle(.secondary)
                                } else if let size = folderSize {
                                    Text(FileEntry.prettySize(size)).bold()
                                } else {
                                    Button(lang("calculate.size")) { calculate() }
                                }
                            }
                        }
                    }
                    Section(lang("permissions")) {
                        TextField("644", text: $permText)
                            .font(.callout.monospaced())
                            .keyboardType(.numberPad)
                        Button(lang("apply")) { applyPermissions() }
                    }
                    Section {
                        Button {
                            AppState.shared.share(url: URL(fileURLWithPath: path))
                        } label: {
                            Label(lang("share"), systemImage: "square.and.arrow.up")
                        }
                    }
                } else {
                    Section {
                        Text("Cannot read this item").foregroundStyle(.secondary)
                    }
                }
            }
            .bileCanvas()
            .navigationTitle(lang("info"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lang("done")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            attrs = LocalFS.attrs(at: path)
            permText = attrs?.permissionsString ?? ""
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    private func calculate() {
        calculating = true
        let p = path
        Task.detached(priority: .userInitiated) {
            let size = LocalFS.size(of: p)
            await MainActor.run {
                folderSize = size
                calculating = false
            }
        }
    }

    private func applyPermissions() {
        let cleaned = permText.trimmingCharacters(in: .whitespaces)
        guard let mode = Int(cleaned, radix: 8), mode > 0 else { return }
        do {
            try LocalFS.setPermissions(path, mode: mode)
            attrs = LocalFS.attrs(at: path)
            permText = attrs?.permissionsString ?? permText
        } catch {
            // Surfaced through the log; the form simply keeps the old value.
        }
    }
}

// MARK: - Text editor

struct TextEditorView: View {
    @EnvironmentObject var lang: LanguageManager
    let path: String
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var original = ""
    @State private var loadError: String? = nil
    @State private var saving = false

    var body: some View {
        NavigationView {
            Group {
                if let loadError {
                    ContentUnavailableCompat(
                        icon: "exclamationmark.triangle",
                        title: loadError
                    )
                } else {
                    ZStack(alignment: .bottomTrailing) {
                        TextEditor(text: $text)
                            .font(.system(.callout, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .background(Color.bileBackground)
                            .padding(6)
                        if text != original {
                            Text("edited")
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.orange.opacity(0.2), in: Capsule())
                                .padding(10)
                        }
                    }
                }
            }
                        .background(Color.bileBackground.ignoresSafeArea())
.navigationTitle((path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lang("done")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(lang("save")) { save() }
                            .disabled(text == original || loadError != nil)
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { load() }
    }

    private func load() {
        Task.detached(priority: .userInitiated) {
            do {
                let data = try LocalFS.readData(path, limit: 2 * 1024 * 1024)
                let decoded = String(data: data, encoding: .utf8) ?? ""
                await MainActor.run {
                    text = decoded
                    original = decoded
                }
            } catch {
                await MainActor.run { loadError = error.localizedDescription }
            }
        }
    }

    private func save() {
        saving = true
        let data = Data(text.utf8)
        Task.detached(priority: .userInitiated) {
            do {
                try LocalFS.writeData(path, data)
                await MainActor.run {
                    original = text
                    saving = false
                }
            } catch {
                await MainActor.run { saving = false }
            }
        }
    }
}

// MARK: - QuickLook

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let vc = QLPreviewController()
        vc.dataSource = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: QLPreviewController, context: Context) {}

    class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }
    }
}

// MARK: - Small compat view

struct ContentUnavailableCompat: View {
    let icon: String
    let title: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
