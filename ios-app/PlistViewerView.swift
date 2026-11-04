import SwiftUI

/// Structured viewer for property lists (XML / binary plist), JSON, and
/// provisioning profiles. Big files render their first N children with a note.
struct PlistViewerView: View {
    @EnvironmentObject var lang: LanguageManager
    let path: String
    @Environment(\.dismiss) private var dismiss

    @State private var root: Any? = nil
    @State private var loadError: String? = nil
    @State private var formatNote = ""
    @State private var expanded: Set<String> = []
    @State private var showEditor = false
    @State private var searchText = ""

    private let maxChildren = 300

    var body: some View {
        NavigationView {
            Group {
                if let loadError {
                    ContentUnavailableCompat(icon: "exclamationmark.triangle", title: loadError)
                } else if root == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if !searchText.isEmpty {
                            Section {
                                Text(lang("plist.filter.hint"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        NodeRow(
                            key: nil,
                            value: root!,
                            idPath: "$",
                            expanded: $expanded,
                            searchText: searchText.lowercased(),
                            depth: 0,
                            maxChildren: maxChildren
                        )

                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color.bileBackground.ignoresSafeArea())
                    .searchable(text: $searchText, prompt: lang("plist.search"))
                }
            }
                        .background(Color.bileBackground.ignoresSafeArea())
.navigationTitle((path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lang("done")) { dismiss() }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Button { expanded = allExpandableIDs() } label: {
                            Label(lang("plist.expand"), systemImage: "arrow.down.right.and.arrow.up.right")
                        }
                        Button { expanded.removeAll() } label: {
                            Label(lang("plist.collapse"), systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        if LocalFS.looksLikeText(path) {
                            Button { showEditor = true } label: {
                                Label(lang("edit.as.text"), systemImage: "pencil")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showEditor) {
                TextEditorView(path: path)
            }
        }
        .navigationViewStyle(.stack)
        .onAppear(perform: load)
    }

    private func load() {
        let p = path
        Task.detached(priority: .userInitiated) {
            do {
                let data = try LocalFS.readData(p, limit: 16 * 1024 * 1024)
                let ext = (p as NSString).pathExtension.lowercased()
                var obj: Any
                var noteText = ""
                if ext == "json" {
                    obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                    noteText = "JSON"
                } else {
                    var fmt = PropertyListSerialization.PropertyListFormat.xml
                    obj = try PropertyListSerialization.propertyList(
                        from: data, options: [], format: &fmt
                    )
                    switch fmt {
                    case .openStep: noteText = "OpenStep plist"
                    case .xml: noteText = "XML plist"
                    case .binary: noteText = "Binary plist"
                    @unknown default: noteText = "plist"
                    }
                }
                await MainActor.run {
                    root = obj
                    formatNote = noteText
                    expanded.insert("$")
                }
            } catch {
                await MainActor.run {
                    loadError = error.localizedDescription
                }
            }
        }
    }

    private func allExpandableIDs() -> Set<String> {
        var ids: Set<String> = ["$"]
        func walk(_ value: Any, _ idPath: String) {
            switch value {
            case let d as [String: Any]:
                ids.insert(idPath)
                if idPath.components(separatedBy: "/").count < 6 {
                    for (k, v) in d { walk(v, idPath + "/" + k) }
                }
            case let a as [Any]:
                ids.insert(idPath)
                if idPath.components(separatedBy: "/").count < 6 {
                    for (i, v) in a.enumerated() { walk(v, idPath + "/\(i)") }
                }
            default:
                break
            }
        }
        if let r = root { walk(r, "$") }
        return ids
    }
}

// MARK: - Recursive row

private struct NodeRow: View {
    let key: String?
    let value: Any
    let idPath: String
    @Binding var expanded: Set<String>
    let searchText: String
    let depth: Int
    let maxChildren: Int

    private var isExpandable: Bool {
        switch value {
        case is [String: Any], is [Any]: return true
        default: return false
        }
    }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { expanded.contains(idPath) },
            set: { on in
                if on { expanded.insert(idPath) } else { expanded.remove(idPath) }
            }
        )
    }

    var body: some View {
        if isExpandable {
            DisclosureGroup(isExpanded: isExpanded) {
                children
            } label: {
                header
            }
        } else {
            header
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let key, !key.isEmpty {
                Text(key)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            scalarSummary
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var scalarSummary: some View {
        switch value {
        case let d as [String: Any]:
            Text(lang("plist.dict").replacingOccurrences(of: "%d", with: "\(d.count)"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        case let a as [Any]:
            Text(lang("plist.array").replacingOccurrences(of: "%d", with: "\(a.count)"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        case let s as String:
            if key != nil {
                Text(s.isEmpty ? "∅" : s)
                    .font(.callout.monospaced())
                    .foregroundStyle(.orange)
                    .lineLimit(searchText.isEmpty ? 2 : nil)
            } else {
                Text(s)
                    .font(.callout.monospaced())
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        case let n as NSNumber:
            // JSON booleans arrive as NSNumber — tell them apart via CFBoolean.
            let text = CFGetTypeID(n) == CFBooleanGetTypeID()
                ? (n.boolValue ? "true" : "false")
                : n.stringValue
            Text(text)
                .font(.callout.monospaced())
                .foregroundStyle(.green)
                .textSelection(.enabled)
        case let date as Date:
            Text(date.formatted(date: .abbreviated, time: .shortened))
                .font(.callout.monospaced())
                .foregroundStyle(.purple)
        case let data as Data:
            Text(lang("plist.data").replacingOccurrences(of: "%d", with: "\(data.count)"))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        default:
            Text("\(value)")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var children: some View {
        let filtered = matchesFilter
        if filtered.isEmpty {
            Text(lang("plist.no.match"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(filtered.prefix(maxChildren).enumerated()), id: \.offset) { _, child in
                child.node
                    .padding(.leading, 10)
            }
            if filtered.count > maxChildren {
                Text(lang("plist.truncated").replacingOccurrences(of: "%d", with: "\(filtered.count - maxChildren)"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Children as (key?, value, idPath) triples, honouring the filter.
    private var matchesFilter: [(key: String?, value: Any, id: String, node: AnyView)] {
        var out: [(String?, Any, String, AnyView)] = []
        func push(_ key: String?, _ v: Any, _ id: String) {
            out.append((key, v, id, AnyView(
                NodeRow(
                    key: key, value: v, idPath: id, expanded: $expanded,
                    searchText: searchText, depth: depth + 1, maxChildren: maxChildren
                )
            )))
        }
        switch value {
        case let d as [String: Any]:
            for (k, v) in d.sorted(by: { $0.key < $1.key }) {
                if searchText.isEmpty
                    || k.lowercased().contains(searchText)
                    || scalarText(v).lowercased().contains(searchText) {
                    push(k, v, idPath + "/" + k)
                }
            }
        case let a as [Any]:
            for (i, v) in a.enumerated() {
                if searchText.isEmpty
                    || scalarText(v).lowercased().contains(searchText) {
                    push("[\(i)]", v, idPath + "/\(i)")
                }
            }
        default:
            break
        }
        return out
    }

    private func scalarText(_ v: Any) -> String {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }
}

extension NodeRow {
    func lang(_ key: String) -> String {
        LanguageManager.shared.t(key)
    }
}
