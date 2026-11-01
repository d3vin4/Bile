import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @EnvironmentObject var state: AppState
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var showImporter = false
    @State private var renameTarget: FileEntry? = nil
    @State private var renameName = ""
    @State private var showRename = false
    @State private var exportTarget: FileEntry? = nil
    @State private var showExporter = false

    var body: some View {
        NavigationView {
            VStack {
                if state.selectedContainer == nil {
                    Text("Open a container from the Apps tab").foregroundStyle(.secondary).padding()
                    Spacer()
                } else {
                    HStack {
                        Button { state.navigateUp() } label: { Image(systemName: "chevron.left") }
                            .disabled(state.currentRelPath.isEmpty)
                        Text(state.breadcrumb()).font(.caption.monospaced())
                        Spacer()
                        Button { showNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                        Button { showImporter = true } label: { Image(systemName: "square.and.arrow.down") }
                    }
                    .padding(.horizontal)

                    if state.isLoadingFiles { ProgressView().padding() }
                    if let e = state.filesError { Text(e).foregroundStyle(.red).font(.caption).padding() }

                    List {
                        ForEach(state.entries) { entry in
                            HStack {
                                Image(systemName: entry.isDir ? "folder.fill" : "doc")
                                VStack(alignment: .leading) {
                                    Text(entry.name)
                                    Text("\(entry.size) bytes").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if entry.isDir { state.navigate(into: entry.name) }
                            }
                            .swipeActions {
                                Button(role: .destructive) { state.deleteEntry(entry) } label: { Label("Delete", systemImage: "trash") }
                                Button { renameTarget = entry; renameName = entry.name; showRename = true } label: { Label("Rename", systemImage: "pencil") }
                                if !entry.isDir {
                                    Button { exportTarget = entry; showExporter = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(state.selectedContainer?.name ?? "Files")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if state.selectedContainer != nil {
                        Button("Close") { state.closeContainer() }
                    }
                }
            }
            .sheet(isPresented: $showNewFolder) {
                VStack {
                    TextField("Folder name", text: $newFolderName)
                        .textFieldStyle(.roundedBorder).padding()
                    Button("Create") {
                        if !newFolderName.isEmpty { state.createFolder(name: newFolderName) }
                        newFolderName = ""
                        showNewFolder = false
                    }
                    Button("Cancel") { showNewFolder = false }
                }.padding()
            }
            .sheet(isPresented: $showRename) {
                VStack {
                    TextField("New name", text: $renameName).textFieldStyle(.roundedBorder).padding()
                    Button("Rename") {
                        if let t = renameTarget, !renameName.isEmpty { state.renameEntry(t, to: renameName) }
                        showRename = false
                    }
                    Button("Cancel") { showRename = false }
                }.padding()
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
                if case .success(let url) = result { state.importFile(from: url) }
            }
            .fileExporter(isPresented: $showExporter, document: exportTarget.map { FileDocumentWrapper(entry: $0, state: state) }, contentType: .data, defaultFilename: exportTarget?.name ?? "file") { result in
                if case .success(let url) = result, let e = exportTarget {
                    state.exportFile(e, to: url)
                }
                exportTarget = nil
            }
        }
    }
}

// Minimal FileDocument wrapper for export
struct FileDocumentWrapper: FileDocument {
    var entry: FileEntry
    var state: AppState
    static var readableContentTypes: [UTType] { [.data] }
    init(entry: FileEntry, state: AppState) { self.entry = entry; self.state = state }
    init(configuration: ReadConfiguration) throws { fatalError() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // read from container into temp then wrap
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(entry.name).path
        let rel = state.currentRelPath.isEmpty ? entry.name : state.currentRelPath + "/" + entry.name
        guard let c = state.selectedContainer else { throw CocoaError(.fileNoSuchFile) }
        try RustBridge.read(pairingPath: state.pairingPath, bundleId: c.bundleId, containerPath: c.path, relPath: rel, bridge: state.bridge, destLocalPath: local, log: { _ in })
        let data = try Data(contentsOf: URL(fileURLWithPath: local))
        return FileWrapper(regularFileWithContents: data)
    }
}
