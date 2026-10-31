import SwiftUI
import UniformTypeIdentifiers
import WorldTreeCore

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct ProfileView: View {
    @EnvironmentObject var model: AppModel
    @State private var importingGEDCOM = false
    @State private var importingDNA = false
    @State private var exporting = false
    @State private var confirmDelete = false
    @State private var dnaConsent = false
    @State private var url = ""
    @State private var token = ""

    private var gedcomTypes: [UTType] {
        [UTType(filenameExtension: "ged"), UTType(filenameExtension: "gedcom"), .plainText, .data].compactMap { $0 }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Family tree (GEDCOM)") {
                    Button { importingGEDCOM = true } label: { Label("Import GEDCOM (.ged)", systemImage: "square.and.arrow.down") }
                    if let r = model.lastImport {
                        LabeledContent("Last import", value: "GEDCOM \(r.version)")
                        LabeledContent("People / families", value: "\(r.people) / \(r.families)")
                        if !r.warnings.isEmpty {
                            DisclosureGroup("\(r.warnings.count) warning(s) — nothing was discarded") {
                                ForEach(r.warnings.prefix(50), id: \.self) { Text($0).font(.caption) }
                            }
                        }
                    }
                    if let home = model.tree.homePersonID {
                        NavigationLink { PersonPicker(title: "Who are you?", selection: Binding(get: { home }, set: { if let v = $0 { model.setHome(v) } })) } label: {
                            LabeledContent("Home person (me)", value: model.graph.name(home))
                        }
                    }
                }
                Section {
                    TextField("http://192.168.1.20:8787", text: $url).textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                    SecureField("API token (printed when the server starts)", text: $token)
                    Button("Save & connect") { model.saveServer(url: url, token: token); token = "" }
                    LabeledContent("Status", value: model.client == nil ? "Not configured" : (model.serverOnline ? "Online" : "Offline"))
                    Toggle("Send my tree to my research server", isOn: Binding(get: { model.shareTreeWithServer }, set: { model.setShareTree($0) }))
                    if model.shareTreeWithServer && model.client != nil {
                        Button("Upload tree now") { Task { await model.uploadTree() } }
                    }
                } header: { Text("Research server") } footer: {
                    Text("Your tree only leaves this iPhone if you turn this on, and only goes to the server you run yourself.")
                }
                if !model.connectors.isEmpty {
                    Section("Research sources") {
                        ForEach(model.connectors) { c in
                            VStack(alignment: .leading) {
                                HStack { Text(c.name); Spacer(); Text(c.status.replacingOccurrences(of: "_", with: " ")).font(.caption).foregroundStyle(c.status == "implemented" ? .green : .orange) }
                                Text(c.notes).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Toggle("Allow automatic merges", isOn: Binding(get: { model.autoMerge.enabled }, set: { model.autoMerge.enabled = $0; model.save() }))
                    if model.autoMerge.enabled {
                        Stepper("Minimum corroborating facts: \(model.autoMerge.minCorroborations)",
                                value: Binding(get: { model.autoMerge.minCorroborations }, set: { model.autoMerge.minCorroborations = $0; model.save() }), in: 2...6)
                    }
                } header: { Text("Duplicate rules") } footer: {
                    Text("Automatic merges require a score of at least 95%, no conflicting facts, and several matching facts beyond the name. Every merge is logged and can be undone.")
                }
                Section {
                    Toggle("I consent to processing my raw DNA file on this device", isOn: $dnaConsent)
                    Button { importingDNA = true } label: { Label("Import raw DNA (23andMe / AncestryDNA)", systemImage: "testtube.2") }
                        .disabled(!dnaConsent)
                    if let d = model.dnaSummary {
                        LabeledContent("Stored", value: "\(d.format), \(d.snpCount) markers")
                        Button("Delete DNA data", role: .destructive) { model.deleteDNA() }
                    }
                } header: { Text("DNA (optional, private)") } footer: {
                    Text("DNA stays encrypted on this iPhone and is never uploaded. Raw DNA alone cannot identify famous relatives; cousin matching requires a consented matching database, which is not connected in v1.0.")
                }
                Section("Privacy & data") {
                    Label("Living people are private by default", systemImage: "lock.fill")
                    Label("Tree stored encrypted (AES-GCM, key in Keychain)", systemImage: "key.fill")
                    Button("Export my tree (JSON)") { exporting = true }
                    Button("Delete everything on this iPhone", role: .destructive) { confirmDelete = true }
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Profile")
            .toolbarBackground(Theme.night, for: .navigationBar)
            .onAppear { url = model.serverURL; Task { await model.refreshGraphAndConnectors() } }
            .fileImporter(isPresented: $importingGEDCOM, allowedContentTypes: gedcomTypes) { result in
                if case .success(let file) = result { readFile(file) { model.importGEDCOM($0) } }
            }
            .fileImporter(isPresented: $importingDNA, allowedContentTypes: [.plainText, .commaSeparatedText, .data]) { result in
                if case .success(let file) = result { readFile(file) { model.importDNA($0) } }
            }
            .fileExporter(isPresented: $exporting, document: ExportDocument(data: model.exportJSON()),
                          contentType: .json, defaultFilename: "world-tree-export") { _ in }
            .confirmationDialog("Delete your entire tree, merge history and DNA data from this iPhone?", isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) { model.deleteEverything() }
            }
        }
    }

    private func readFile(_ url: URL, _ handle: (Data) -> Void) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? Data(contentsOf: url) { handle(data) } else { model.message = "Could not read the file." }
    }
}
