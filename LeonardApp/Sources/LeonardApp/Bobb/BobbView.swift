import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LeonardCore

struct BobbView: View {
    @Bindable var workspace: BobbWorkspace
    @State private var tab = "identity"
    @State private var name = "Bobb"
    @State private var character = "Practical and concise."
    @State private var profile = "general"
    @State private var domain = ""
    @State private var aliases = ""
    @State private var goal = ""
    @State private var workName = ""
    @State private var workKind = "request"
    @State private var surface = "browser"
    @State private var url = ""
    @State private var scheduleKind = "daily"
    @State private var hour = 9
    @State private var minute = 0
    @State private var weekday = 0
    @State private var event = "mail.opened"
    @State private var once = Date().addingTimeInterval(3600)
    @State private var projectSteps = ""
    @State private var planning = false
    @State private var apiKey = ""
    @State private var connectorName = ""
    @State private var connectorExecutable = ""
    @State private var connectorArguments = ""

    init(workspace: BobbWorkspace, initialTab: String = "identity") {
        self.workspace = workspace
        _tab = State(initialValue: initialTab)
    }

    private var pages: [(id: String, title: String, icon: String)] {
        [("identity", t("Your Bobb", "Il tuo Bobb"), "person.crop.circle"),
         ("boundaries", t("Boundaries", "Confini"), "hand.raised"),
         ("work", t("Work", "Lavoro"), "checklist"),
         ("activity", t("Activity", "Attività"), "clock"),
         ("brain", t("Brain", "Cervello"), "cpu"),
         ("computers", t("Computers", "Computer"), "desktopcomputer")]
    }

    private var state: AppState { workspace.state }
    private func t(_ en: String, _ it: String) -> String { BobbCopy.t(en, it) }
    private func binding<T>(_ path: WritableKeyPath<BobbSettings, T>) -> Binding<T> {
        Binding(get: { state.settings.bobb[keyPath: path] }, set: { value in workspace.coordinator.updateSettings { $0.bobb[keyPath: path] = value } })
    }
    private func hint(_ text: String) -> some View { Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    LeonardMark(size: 64)
                    Text("Bobb").font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(t("A little help.\nRoom for big ideas.", "Un piccolo aiuto.\nSpazio alle grandi idee."))
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(.horizontal, 12).padding(.top, 12)
                BobbGlassGroup {
                    VStack(spacing: 6) {
                        ForEach(pages, id: \.id) { page in
                            Button {
                                tab = page.id
                            } label: {
                                Label(page.title, systemImage: page.icon)
                                    .font(.system(size: 13, weight: tab == page.id ? .semibold : .regular))
                                    .foregroundStyle(tab == page.id ? Theme.accent : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14).padding(.vertical, 12)
                                    .background {
                                        if tab == page.id {
                                            Color.clear.bobbGlass(radius: 14, tint: Theme.accent.opacity(0.14), interactive: true)
                                        }
                                    }
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(tab == page.id ? .isSelected : [])
                        }
                    }
                }
                Spacer()
                Label(t("Your Mac. Your boundaries.", "Il tuo Mac. I tuoi confini."), systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary).padding(12)
            }
            .padding(12).frame(width: 190).bobbGlass(radius: 24)
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pages.first { $0.id == tab }?.title ?? "Bobb")
                            .font(.system(size: 25, weight: .bold, design: .rounded))
                        Text(workspace.activeAgent.name).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker(t("Active Bobb", "Bobb attivo"), selection: binding(\.activeAgent)) {
                        ForEach(workspace.agents) { agent in Text(agent.name).tag(agent.id) }
                    }.labelsHidden().frame(width: 130).help(t("Active Bobb", "Bobb attivo"))
                    Toggle(t("Background", "Background"), isOn: binding(\.backgroundEnabled))
                        .toggleStyle(.switch).font(.caption).fixedSize()
                }.padding(.horizontal, 8)
                if let message = workspace.message {
                    HStack(alignment: .top) {
                        Label(message, systemImage: "info.circle").font(.callout)
                        Spacer()
                        Button(t("Dismiss", "Chiudi")) { workspace.message = nil }
                    }.padding(12).bobbGlass(tint: Theme.attention.opacity(0.10))
                }
                pageContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .scrollContentBackground(.hidden)
            }.padding(.vertical, 12)
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 660)
        .bobbWindowStyle()
        .onAppear { loadIdentity(); loadAliases() }
        .onChange(of: workspace.activeAgent.id) { _, _ in loadIdentity() }
        .onChange(of: workspace.snapshot?.agents) { _, _ in loadIdentity() }
    }

    @ViewBuilder private var pageContent: some View {
        switch tab {
        case "boundaries": boundaries
        case "work": work
        case "activity": activity
        case "brain": brain
        case "computers": computers
        default: identity
        }
    }

    private var identity: some View {
        Form {
            Section(t("Create your Bobb", "Crea il tuo Bobb")) {
                TextField(t("Name", "Nome"), text: $name)
                TextField(t("Character", "Carattere"), text: $character, axis: .vertical).lineLimit(2...4)
                Picker(t("Profile", "Profilo"), selection: $profile) {
                    Text(t("General", "Generale")).tag("general")
                    Text(t("Development", "Sviluppo")).tag("development")
                    Text(t("Secretary", "Segreteria")).tag("secretary")
                }
                HStack {
                    Button(t("Save", "Salva")) { saveAgent(id: workspace.activeAgent.id) }
                    Button(t("Create another Bobb", "Crea un altro Bobb")) { saveAgent(id: UUID().uuidString) }
                    Button(t("Remove", "Rimuovi"), role: .destructive) { workspace.delete("agent", id: workspace.activeAgent.id) }
                        .disabled(workspace.agents.count <= 1)
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section(t("Introduction", "Presentazione")) {
                Text(workspace.activeAgent.introduction)
                if let apps = state.stats?.memory?.apps, !apps.isEmpty {
                    hint(t("Your local memory includes: ", "La tua memoria locale comprende: ") + apps.map(\.app).joined(separator: ", "))
                } else {
                    hint(t("I haven't observed your work yet. Connect the apps you want me to use in Boundaries.", "Non ho ancora osservato il tuo lavoro. Collega nei Confini le app che vuoi farmi usare."))
                }
                Button(t("Introduce yourself aloud", "Presentati a voce")) {
                    var settings = state.settings; settings.bobb.speakResponses = true
                    workspace.voice.speak(workspace.activeAgent.introduction, settings: settings)
                }
            }
            hint(t("Each Bobb has its own assignments and browser session. The physical desktop is shared one task at a time.", "Ogni Bobb ha i suoi incarichi e una sessione browser separata. Lo schermo fisico è condiviso, un incarico alla volta."))
        }.formStyle(.grouped)
    }
    private func loadIdentity() { let a = workspace.activeAgent; name = a.name; character = a.character; profile = a.profile }
    private func saveAgent(id: String) {
        let data: JSONValue = .object(["id": .string(id), "name": .string(name), "character": .string(character), "profile": .string(profile)])
        Task {
            if await workspace.command("put", .object(["kind": "agent", "data": data])) != nil {
                workspace.coordinator.updateSettings { $0.bobb.activeAgent = id }
            }
        }
    }

    private var boundaries: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hint(t("Connect only the apps and websites Bobb may use. Password managers and secure fields stay protected.", "Collega solo le app e i siti che Bobb può usare. Gestori di password e campi segreti restano protetti."))
                HStack {
                    Button(t("Connect an app…", "Collega un’app…"), action: connectApp)
                    Button(t("Connect Bobb Browser", "Collega Browser di Bobb")) { connect(id: "bobb.browser", name: "Bobb Browser") }
                    TextField(t("Website hostname", "Dominio del sito"), text: $domain)
                    Button(t("Connect site", "Collega sito")) {
                        let host = domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                        if !host.isEmpty, !host.contains("/"), !host.contains(" ") { connect(id: "web:\(host)", name: host); domain = "" }
                    }
                }
                ForEach(state.settings.bobb.boundaries.apps) { app in
                    GroupBox {
                        VStack(alignment: .leading) {
                            HStack { Text(app.name).bold(); Text(app.id).font(.caption).foregroundStyle(.secondary); Spacer()
                                Button(t("Disconnect", "Scollega"), role: .destructive) { workspace.coordinator.updateSettings { $0.bobb.boundaries.apps.removeAll { $0.id == app.id } } }
                            }
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading) {
                                ForEach(ActionCategory.allCases, id: \.rawValue) { category in
                                    Picker(categoryName(category), selection: Binding(get: { app.mode(category) }, set: { value in
                                        workspace.coordinator.updateSettings { s in
                                            if let i = s.bobb.boundaries.apps.firstIndex(where: { $0.id == app.id }) { s.bobb.boundaries.apps[i].actions[category.rawValue] = value }
                                        }
                                    })) { ForEach(BoundaryMode.allCases, id: \.rawValue) { mode in Text(modeName(mode)).tag(mode) } }
                                }
                            }
                        }.padding(6)
                    }
                }
                GroupBox(t("Rules in your words", "Regole a parole")) {
                    VStack(alignment: .leading) {
                        TextEditor(text: Binding(get: { state.settings.bobb.boundaries.rules.joined(separator: "\n") }, set: { value in
                            workspace.coordinator.updateSettings { $0.bobb.boundaries.rules = value.split(separator: "\n").map(String.init) }
                        })).frame(height: 70)
                        hint(t("For example: never message my boss without asking. Unrecognized rules ask for review. Natural language cannot grant extra permissions.", "Esempio: non scrivere mai al mio capo senza chiedermelo. Le regole non riconosciute chiedono una verifica. Le regole a parole non concedono permessi aggiuntivi."))
                        TextField(t("People: boss=Name,email; one alias per line", "Persone: capo=Nome,email; una voce per riga"), text: $aliases, axis: .vertical).lineLimit(2...4)
                        Button(t("Save people", "Salva persone"), action: saveAliases)
                    }
                }
                Toggle(t("Working hours", "Fasce orarie di lavoro"), isOn: binding(\.boundaries.hoursEnabled))
                if state.settings.bobb.boundaries.hoursEnabled {
                    HStack {
                        Stepper(t("From ", "Dalle ") + "\(state.settings.bobb.boundaries.fromHour):00", value: binding(\.boundaries.fromHour), in: 0...23)
                        Stepper(t("Until ", "Alle ") + "\(state.settings.bobb.boundaries.toHour):00", value: binding(\.boundaries.toHour), in: 0...23)
                    }
                    hint(t("Times use this Mac's local time. Equal start and end block work all day.", "Gli orari usano il fuso di questo Mac. Inizio e fine uguali bloccano il lavoro tutto il giorno."))
                }
            }.padding(8)
        }
    }
    private func modeName(_ mode: BoundaryMode) -> String {
        switch mode { case .allow: t("On its own", "Da solo"); case .ask: t("Ask", "Chiedi"); case .deny: t("Never", "Mai") }
    }
    private func categoryName(_ category: ActionCategory) -> String {
        switch category {
        case .navigate: t("Navigate", "Navigare"); case .write: t("Write drafts", "Scrivere bozze"); case .send: t("Send / confirm", "Inviare / confermare")
        case .pay: t("Pay", "Pagare"); case .delete: t("Delete", "Cancellare"); case .publish: t("Publish", "Pubblicare")
        case .settings: t("Settings", "Impostazioni"); case .execute: t("Run commands / tools", "Eseguire comandi / strumenti")
        }
    }
    private func connect(id: String, name: String) {
        workspace.coordinator.updateSettings { s in if !s.bobb.boundaries.apps.contains(where: { $0.id == id }) { s.bobb.boundaries.apps.append(AppBoundary(id: id, name: name)) } }
    }
    private func connectApp() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = true; picker.allowedContentTypes = [.applicationBundle]
        guard picker.runModal() == .OK, let url = picker.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        connect(id: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
    }
    private func loadAliases() { aliases = state.settings.bobb.boundaries.people.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value.joined(separator: ",") }.joined(separator: "\n") }
    private func saveAliases() {
        var people: [String: [String]] = [:]
        for line in aliases.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty { people[parts[0]] = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        }
        workspace.coordinator.updateSettings { $0.bobb.boundaries.people = people }
    }

    private var work: some View {
        Form {
            Section(t("New work", "Nuovo lavoro")) {
                Picker(t("Type", "Tipo"), selection: $workKind) {
                    Text(t("Request", "Richiesta")).tag("request"); Text(t("Standing assignment", "Incarico permanente")).tag("job"); Text(t("Project", "Progetto")).tag("project")
                }
                TextField(t("Name", "Nome"), text: $workName)
                TextField(t("Objective", "Obiettivo"), text: $goal, axis: .vertical).lineLimit(2...5)
                Picker(t("Computer", "Computer"), selection: $surface) {
                    Text(t("Hidden browser", "Browser nascosto")).tag("browser"); Text(t("Mac desktop", "Schermo del Mac")).tag("desktop"); Text("MCP").tag("mcp")
                }
                if surface != "desktop" { TextField(surface == "browser" ? "https://…" : t("Connector name", "Nome connettore"), text: $url) }
                if workKind == "job" { scheduling }
                if workKind == "project" {
                    Button(planning ? t("Planning…", "Pianifico…") : t("Propose subtasks", "Proponi sotto-attività")) {
                        planning = true
                        Task { projectSteps = (await workspace.planProject(goal: goal, profile: workspace.activeAgent.profile))?.joined(separator: "\n") ?? ""; planning = false }
                    }.disabled(planning || goal.isEmpty)
                    TextEditor(text: $projectSteps).frame(height: 130)
                    hint(t("Review and edit the subtasks, one per line. Bobb saves progress after each one and pauses when it needs you.", "Controlla e modifica le sotto-attività, una per riga. Bobb salva l’avanzamento dopo ciascuna e si ferma quando ha bisogno di te."))
                }
                Button(workKind == "request" ? t("Start", "Avvia") : t("Save and enable", "Salva e attiva"), action: saveWork)
                    .disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (workKind == "project" && projectSteps.isEmpty))
                hint(t("Standing assignments run while this Mac is awake, Bobb is open, and background work is enabled. Desktop work waits until you are away; browser work can run concurrently.", "Gli incarichi partono quando il Mac è sveglio, Bobb è aperto e il lavoro in background è attivo. Il lavoro sullo schermo aspetta che tu sia assente; i browser possono lavorare insieme."))
            }
            entities("project", items: workspace.snapshot?.projects ?? [])
            entities("job", items: workspace.snapshot?.jobs ?? [])
            Section(t("Suggested routines", "Routine proposte")) {
                ForEach(Array((workspace.snapshot?.routines ?? []).enumerated()), id: \.offset) { _, routine in
                    HStack {
                        Text(routine["goal"]?.stringValue ?? "")
                        Spacer()
                        Button(t("Prepare assignment", "Prepara incarico")) {
                            workKind = "job"; goal = routine["goal"]?.stringValue ?? ""; scheduleKind = "weekly"
                            weekday = Int(routine["weekday"]?.numberValue ?? 0); hour = Int(routine["hour"]?.numberValue ?? 9); minute = Int(routine["minute"]?.numberValue ?? 0)
                        }
                        Button(t("Dismiss", "Ignora")) { Task { _ = await workspace.command("dismiss_routine", .object(["id": routine["id"] ?? .null])) } }
                    }
                }
            }
        }.formStyle(.grouped)
    }
    private var scheduling: some View {
        Group {
            Picker(t("Trigger", "Avvio"), selection: $scheduleKind) {
                Text(t("Once", "Una volta")).tag("once"); Text(t("Daily", "Ogni giorno")).tag("daily")
                Text(t("Weekly", "Ogni settimana")).tag("weekly"); Text(t("On event", "Su evento")).tag("event")
            }
            if scheduleKind == "once" { DatePicker(t("When", "Quando"), selection: $once) }
            else if scheduleKind == "event" {
                Picker(t("Event", "Evento"), selection: $event) {
                    Text(t("Mail opened", "Mail aperta")).tag("mail.opened"); Text(t("New chat message", "Nuovo messaggio in chat")).tag("message.opened")
                    Text(t("Meeting soon", "Riunione imminente")).tag("calendar.upcoming")
                }
            } else {
                HStack { Stepper("\(hour):00", value: $hour, in: 0...23); Stepper(t("Minute ", "Minuto ") + "\(minute)", value: $minute, in: 0...59) }
                if scheduleKind == "weekly" {
                    Picker(t("Day", "Giorno"), selection: $weekday) {
                        ForEach(0..<7, id: \.self) { index in Text([t("Monday", "Lunedì"),t("Tuesday", "Martedì"),t("Wednesday", "Mercoledì"),t("Thursday", "Giovedì"),t("Friday", "Venerdì"),t("Saturday", "Sabato"),t("Sunday", "Domenica")][index]).tag(index) }
                    }
                }
            }
        }
    }
    private func saveWork() {
        if workKind == "request" { workspace.run(goal: goal, surface: surface, url: url, agentId: workspace.activeAgent.id); tab = "activity"; return }
        var data: [String: JSONValue] = ["name": .string(workName.isEmpty ? String(goal.prefix(80)) : workName), "goal": .string(goal),
            "surface": .string(surface), "url": .string(url), "agent_id": .string(workspace.activeAgent.id), "enabled": true]
        if workKind == "project" { data["steps"] = .array(projectSteps.split(separator: "\n").map { .string(String($0)) }) }
        else {
            var schedule: [String: JSONValue] = ["kind": .string(scheduleKind)]
            if scheduleKind == "once" { schedule["at"] = .number(once.timeIntervalSince1970) }
            else if scheduleKind == "event" { schedule["event"] = .string(event) }
            else { schedule["hour"] = .number(Double(hour)); schedule["minute"] = .number(Double(minute)); schedule["timezone"] = .string(TimeZone.current.identifier)
                if scheduleKind == "weekly" { schedule["weekday"] = .number(Double(weekday)) }
            }
            data["schedule"] = .object(schedule)
        }
        workspace.put(workKind, data: .object(data))
    }
    private func entities(_ kind: String, items: [JSONValue]) -> some View {
        Section(kind == "project" ? t("Projects", "Progetti") : t("Standing assignments", "Incarichi permanenti")) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, entity in
                VStack(alignment: .leading) {
                    HStack {
                        Text(entity["name"]?.stringValue ?? "").bold(); Spacer()
                        Button(entity["enabled"]?.boolValue == true ? t("Pause", "Pausa") : t("Resume", "Riprendi")) { workspace.toggle(kind, entity: entity) }
                        Button(t("Remove", "Rimuovi"), role: .destructive) { workspace.delete(kind, id: entity["id"]?.stringValue ?? "") }
                    }
                    hint(entity["goal"]?.stringValue ?? "")
                    if kind == "project", case .array(let steps)? = entity["steps"] {
                        let done = workspace.snapshot?.runs.filter { $0.projectId == entity["id"]?.stringValue && $0.status == "done" }.count ?? 0
                        hint("\(done) / \(steps.count) " + t("subtasks completed", "sotto-attività completate"))
                    }
                }
            }
        }
    }

    private var activity: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(workspace.remoteReplies) { reply in
                    GroupBox(t("iMessage reply awaiting permission", "Risposta iMessage in attesa di permesso")) {
                        VStack(alignment: .leading) { Text(reply.address).font(.caption); Text(reply.text)
                            HStack { Button(t("Send once", "Invia una volta")) { workspace.sendRemoteReply(reply, allow: true) }
                                Button(t("Discard", "Scarta")) { workspace.sendRemoteReply(reply, allow: false) } }
                        }
                    }
                }
                ForEach(workspace.executions) { execution in
                    GroupBox(workspace.agents.first { $0.id == execution.run.agentId }?.name ?? "Bobb") {
                        TaskView(state: execution.state, actions: TaskActions(stop: { workspace.stop(execution) },
                            allow: { workspace.allow($0, execution: execution) }, undo: { Task { await execution.loop.undoLast() } },
                            close: { workspace.executions.removeAll { $0.id == execution.id && $0.finished } }))
                        if execution.run.surface == "browser" { Button(t("Open its browser", "Apri il suo browser")) { workspace.webComputer(agentId: execution.run.agentId).inspect() } }
                    }
                }
                Divider()
                Text(t("Saved activity", "Attività salvata")).font(.headline)
                ForEach(workspace.snapshot?.runs ?? []) { run in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading) {
                            Text(run.goal); hint(run.status + " · " + run.surface)
                            if !run.report.isEmpty { Text(run.report).font(.callout).textSelection(.enabled) }
                        }
                        Spacer()
                        if ["waiting", "failed", "interrupted", "stopped"].contains(run.status), !workspace.executions.contains(where: { $0.id == run.id && !$0.finished }) {
                            Button(t("Review and retry", "Rivedi e riprova")) { workspace.retry(run) }
                        }
                        if run.status == "queued" || run.status == "waiting" {
                            Button(t("Cancel", "Annulla")) {
                                if let execution = workspace.executions.first(where: { $0.id == run.id && !$0.finished }) { workspace.stop(execution) }
                                else { Task { _ = await workspace.command("cancel_run", .object(["id": .string(run.id)])) } }
                            }
                        }
                    }
                }
            }.padding()
        }
    }

    private var brain: some View {
        Form {
            Section(t("Local model", "Modello locale")) {
                let ram = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
                let recommended = LocalModelOption.recommended(memoryBytes: ProcessInfo.processInfo.physicalMemory)
                Text("\(ram) GB RAM · " + t("suggested size: ", "dimensione suggerita: ") + recommended.parameters)
                hint(t("Select a downloaded MLX checkpoint folder to use a larger model. Estimates leave room for macOS and context; performance depends on the model.", "Seleziona una cartella MLX già scaricata per usare un modello più grande. Le stime lasciano spazio a macOS e al contesto; le prestazioni dipendono dal modello."))
                Text(state.settings.bobb.localModelPath.isEmpty ? t("Bundled 3B model", "Modello 3B predefinito") : state.settings.bobb.localModelPath).font(.caption).textSelection(.enabled)
                HStack { Button(t("Choose checkpoint…", "Scegli modello…"), action: chooseModel)
                    Button(t("Use default", "Usa predefinito")) { workspace.coordinator.updateSettings { $0.bobb.localModelPath = "" } }
                }
            }
            Section(t("Optional cloud brain", "Cervello cloud opzionale")) {
                Toggle(t("Use my cloud API", "Usa la mia API cloud"), isOn: binding(\.cloud.enabled))
                TextField(t("HTTPS chat-completions endpoint", "Endpoint HTTPS chat-completions"), text: binding(\.cloud.endpoint))
                TextField(t("Model ID", "ID modello"), text: binding(\.cloud.model))
                SecureField(t("API key", "Chiave API"), text: $apiKey)
                Button(t("Save key in Keychain", "Salva chiave nel Portachiavi")) {
                    do { try CloudKeychain.save(apiKey, endpoint: state.settings.bobb.cloud.endpoint); apiKey = ""; workspace.message = t("API key saved.", "Chiave API salvata.") }
                    catch { workspace.message = error.localizedDescription }
                }
                TextField(t("Extra private terms, one per line", "Altri termini privati, uno per riga"), text: Binding(get: { state.settings.bobb.cloud.privateTerms.joined(separator: "\n") }, set: { value in
                    workspace.coordinator.updateSettings { $0.bobb.cloud.privateTerms = value.split(separator: "\n").map(String.init) }
                }), axis: .vertical).lineLimit(2...4)
                hint(t("Cloud is off by default. Bobb redacts recognized names, addresses, payment details, secrets and your private terms before sending. Redaction cannot recognize every sensitive fact. The exact redacted request is recorded locally.", "Il cloud parte spento. Bobb oscura nomi riconosciuti, indirizzi, dati di pagamento, segreti e i tuoi termini privati prima dell’invio. L’oscuramento non può riconoscere ogni fatto sensibile. La richiesta oscurata esatta viene registrata sul Mac."))
                Button(t("Open outgoing-data log", "Apri registro dei dati in uscita")) { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.dataDirectory.appendingPathComponent("cloud-egress.jsonl")]) }
            }
            Toggle(t("Speak responses", "Risposte a voce"), isOn: binding(\.speakResponses))
        }.formStyle(.grouped)
    }
    private func chooseModel() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = false
        guard picker.runModal() == .OK, let url = picker.url, FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path) else { return }
        workspace.coordinator.updateSettings { $0.bobb.localModelPath = url.path }
    }

    private var computers: some View {
        Form {
            Section(t("Bobb Browser", "Browser di Bobb")) {
                Button(t("Open the active Bobb's browser", "Apri il browser del Bobb attivo")) { workspace.webComputer(agentId: workspace.activeAgent.id).inspect() }
                hint(t("Log in inside this browser when a website needs your account. Its cookies are local and separate from your normal browser.", "Accedi da questo browser quando un sito richiede il tuo account. I cookie restano sul Mac e sono separati dal tuo browser abituale."))
            }
            Section("iMessage") {
                TextField(t("Your own iMessage address", "Il tuo indirizzo iMessage"), text: binding(\.selfAddress))
                Toggle(t("Listen to my self chat", "Leggi la chat con me stesso"), isOn: binding(\.iMessageEnabled))
                hint(workspace.messages.status)
                hint(t("On iPhone: /bobb your question, /bobb status, or /bobb run https://site.example your task. Requires Full Disk Access and Messages Automation on the Mac. Replies follow Messages' send boundary.", "Da iPhone: /bobb la tua domanda, /bobb status oppure /bobb run https://sito.example il tuo incarico. Richiede Accesso completo al disco e Automazione di Messaggi sul Mac. Le risposte rispettano il Confine di invio di Messaggi."))
            }
            Section(t("Optional MCP connectors", "Connettori MCP opzionali")) {
                ForEach(state.settings.bobb.connectors) { config in
                    HStack { Text(config.id); hint(config.executable); Spacer()
                        Button(t("Remove", "Rimuovi"), role: .destructive) { workspace.coordinator.updateSettings { $0.bobb.connectors.removeAll { $0.id == config.id }; $0.bobb.boundaries.apps.removeAll { $0.id == "mcp:\(config.id)" } } }
                    }
                }
                TextField(t("Connector name", "Nome connettore"), text: $connectorName)
                TextField(t("Absolute executable path", "Percorso assoluto dell’eseguibile"), text: $connectorExecutable)
                TextField(t("Arguments, one per line", "Argomenti, uno per riga"), text: $connectorArguments, axis: .vertical).lineLimit(1...3)
                Button(t("Enable local connector", "Attiva connettore locale")) {
                    let config = MCPConfiguration(id: connectorName, executable: connectorExecutable, arguments: connectorArguments.split(separator: "\n").map(String.init), enabled: true)
                    guard !config.id.isEmpty, config.executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: config.executable) else { return }
                    workspace.coordinator.updateSettings { s in s.bobb.connectors.removeAll { $0.id == config.id }; s.bobb.connectors.append(config) }
                    connect(id: "mcp:\(config.id)", name: "MCP \(config.id)")
                    connectorName = ""; connectorExecutable = ""; connectorArguments = ""
                }
                hint(t("Only explicitly configured stdio servers run. Review the executable yourself; it runs with your account's permissions. Every tool call follows its connector's command boundary.", "Partono solo server stdio configurati da te. Verifica l’eseguibile: viene avviato con i permessi del tuo account. Ogni chiamata rispetta il Confine comandi del connettore."))
            }
            Section(t("Experimental virtual Mac", "Mac virtuale sperimentale")) {
                Text(workspace.virtualMac.status)
                if workspace.virtualMac.progress > 0, workspace.virtualMac.progress < 1 { ProgressView(value: workspace.virtualMac.progress) }
                Toggle(t("Allow guest network at next start", "Consenti rete al guest al prossimo avvio"), isOn: Binding(get: { workspace.virtualMac.networkEnabled }, set: { workspace.virtualMac.networkEnabled = $0 }))
                HStack {
                    Button(t("Install from IPSW…", "Installa da IPSW…")) { workspace.virtualMac.installFromPicker() }.disabled(workspace.virtualMac.installed)
                    Button(t("Start", "Avvia")) { workspace.virtualMac.start() }.disabled(!workspace.virtualMac.installed || workspace.virtualMac.running)
                    Button(t("Open", "Apri")) { workspace.virtualMac.inspect() }
                    Button(t("Shut down", "Spegni")) { workspace.virtualMac.stop() }
                }
                hint(t("Apple silicon, 24 GB RAM and a local macOS restore image. A separate 64 GB sparse disk, no shared folders. This preview provides installation and manual inspection; autonomous guest control is not yet available.", "Apple silicon, 24 GB di RAM e un’immagine macOS locale. Disco sparso separato da 64 GB, nessuna cartella condivisa. Questa anteprima offre installazione e controllo manuale; l’automazione dentro il guest non è ancora disponibile."))
            }
        }.formStyle(.grouped)
    }
}
