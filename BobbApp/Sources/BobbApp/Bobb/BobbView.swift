import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BobbCore

struct BobbView: View {
    @Bindable var workspace: BobbWorkspace
    @State private var tab = "today"
    @State private var name = "Bobb"
    @State private var character = "Practical and concise."
    @State private var profile = "general"
    @State private var appFilter = ""
    @State private var discoveredApps: [AppBoundary] = []
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
    @State private var connectorName = ""
    @State private var connectorExecutable = ""
    @State private var connectorArguments = ""
    @State private var guestAddress = ""
    @State private var guestUser = ""
    @State private var guestKey = ""

    init(workspace: BobbWorkspace, initialTab: String = "today") {
        self.workspace = workspace
        _tab = State(initialValue: initialTab)
    }

    private var pages: [(id: String, title: String, icon: String)] {
        [("today", t("For you", "Per te"), "sparkles"),
         ("identity", t("Your Bobb", "Il tuo Bobb"), "person.crop.circle"),
         ("boundaries", t("Boundaries", "Confini"), "hand.raised"),
         ("work", t("Work", "Lavoro"), "checklist"),
         ("activity", t("Activity", "Attività"), "clock"),
         ("brain", t("Brain", "Cervello"), "cpu"),
         ("computers", t("Computers", "Computer"), "desktopcomputer")]
    }

    private var state: AppState { workspace.state }
    private func t(_ en: String, _ it: String) -> String { BobbCopy.t(en, it) }
    private func binding<T>(_ path: WritableKeyPath<BobbWorkspaceSettings, T>) -> Binding<T> {
        Binding(get: { state.settings.bobb[keyPath: path] }, set: { value in workspace.coordinator.updateSettings { $0.bobb[keyPath: path] = value } })
    }
    private func hint(_ text: String) -> some View { Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    BobbMark(size: 64)
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
                                    .foregroundStyle(tab == page.id ? Theme.accentInk : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14).padding(.vertical, 12)
                                    .background {
                                        if tab == page.id {
                                            RoundedRectangle(cornerRadius: 14).fill(Theme.accent.opacity(0.14))
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
                }.padding(14).bobbGlass(radius: 20)
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
        .onAppear { loadIdentity(); loadAliases(); discoveredApps = InstalledApps.shared.boundaries() }
        .onChange(of: workspace.activeAgent.id) { _, _ in loadIdentity() }
        .onChange(of: workspace.snapshot?.agents) { _, _ in loadIdentity() }
    }

    @ViewBuilder private var pageContent: some View {
        switch tab {
        case "today": today
        case "boundaries": boundaries
        case "work": work
        case "activity": activity
        case "brain": brain
        case "computers": computers
        default: identity
        }
    }

    private var today: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(t("A step ahead", "Un passo avanti")) {
                    VStack(alignment: .leading, spacing: 10) {
                        hint(t("Bobb connects what you are working on with a useful next step. Suggestions explain why and show the source. You decide what to prepare.", "Bobb collega ciò su cui lavori a un prossimo passo utile. I suggerimenti spiegano il perché e mostrano la fonte. Scegli tu cosa preparare."))
                        Toggle(t("Suggest next steps from my apps", "Suggerisci prossimi passi dalle mie app"), isOn: Binding(
                            get: { state.settings.contextProactive },
                            set: { value in workspace.coordinator.updateSettings { $0.contextProactive = value } }))
                        if !state.watching {
                            Label(t("Observation is paused", "L’osservazione è in pausa"), systemImage: "pause.circle")
                            Button(t("Resume observation", "Riprendi osservazione")) { workspace.coordinator.setWatching(true) }
                        } else if !state.modelInstalled || !state.connection.isReady {
                            hint(t("Local intelligence is preparing. Check progress in the menu bar.", "L’intelligenza locale si sta preparando. Controlla l’avanzamento nel menu."))
                        } else if !AXIsProcessTrusted() {
                            hint(t("Grant Accessibility from the menu bar to let Bobb understand your apps.", "Concedi Accessibilità dal menu per permettere a Bobb di comprendere le tue app."))
                        } else if !state.settings.memoryEnabled {
                            hint(t("Enable local memory in Settings to receive context suggestions.", "Attiva la memoria locale nelle Impostazioni per ricevere suggerimenti dal contesto."))
                        }
                        hint(t("Suggestions work without Background. Background controls execution of your assignments.", "I suggerimenti funzionano anche senza Background. Background controlla l’esecuzione degli incarichi."))
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                ForEach(state.promisesDue()) { promise in
                    GroupBox(t("A commitment to follow up", "Un impegno da seguire")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(promise.what).font(.headline)
                            hint(MenuBarPopoverView.promiseDetail(promise))
                            HStack {
                                Button(t("Mark done", "Segna completato")) { workspace.coordinator.updateCommitment(promise.id, status: "done") }
                                Button(t("Tomorrow", "Domani")) {
                                    let next = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date().addingTimeInterval(86400)
                                    workspace.coordinator.updateCommitment(promise.id, dueTs: next.timeIntervalSince1970)
                                }
                                Button(t("Not a commitment", "Non è un impegno")) { workspace.coordinator.updateCommitment(promise.id, status: "dismissed") }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }
                ForEach(workspace.snapshot?.initiatives ?? []) { initiative in
                    initiativeCard(initiative)
                }
                ForEach(state.forYou, id: \.id) { decision in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(decision.suggestion?.title ?? decision.explanation ?? "Bobb").font(.headline)
                            if let explanation = decision.explanation { hint(explanation) }
                            HStack {
                                Button(t("Prepare", "Prepara")) { workspace.coordinator.approve(decision) }
                                Button(t("Dismiss", "Ignora")) { workspace.coordinator.dismiss(decision) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }
                if !(workspace.snapshot?.routines ?? []).isEmpty {
                    GroupBox(t("A routine I noticed", "Una routine che ho notato")) {
                        VStack(alignment: .leading, spacing: 8) {
                            hint(t("You repeated some tasks on several weeks. Review them and choose whether to make them assignments.", "Hai ripetuto alcune attività in più settimane. Rivedile e scegli se trasformarle in incarichi."))
                            Button(t("Review routines", "Rivedi routine")) { tab = "work" }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }
                let blocked = workspace.snapshot?.runs.filter { ["waiting", "interrupted", "failed"].contains($0.status) } ?? []
                if !blocked.isEmpty {
                    GroupBox(t("Work needs your attention", "Un lavoro richiede attenzione")) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(blocked.prefix(3)) { run in Text(run.goal).lineLimit(2) }
                            Button(t("Review activity", "Rivedi attività")) { tab = "activity" }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }
                if state.promisesDue().isEmpty && state.forYou.isEmpty && (workspace.snapshot?.initiatives ?? []).isEmpty {
                    hint(t("No new suggestion yet. Work normally in your apps: Bobb looks for unresolved requests, missing information and actionable errors. It learns from what you accept or dismiss.", "Ancora nessun suggerimento. Lavora normalmente nelle tue app: Bobb cerca richieste aperte, informazioni mancanti ed errori su cui intervenire. Impara da ciò che accetti o ignori."))
                }
                if let muted = workspace.snapshot?.mutedInitiativeApps, !muted.isEmpty {
                    GroupBox(t("What I learned", "Cosa ho imparato")) {
                        VStack(alignment: .leading, spacing: 8) {
                            hint(t("After three dismissals I stopped context suggestions from: ", "Dopo tre rifiuti ho sospeso i suggerimenti dal contesto di: ") + muted.joined(separator: ", "))
                            Button(t("Reset this learning", "Azzera questo apprendimento")) {
                                Task { _ = await workspace.command("reset_initiative_learning") }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }
            }.padding(8)
        }
    }

    private func initiativeCard(_ initiative: ProactiveInitiative) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label(initiative.title, systemImage: "sparkles").font(.headline)
                hint(initiative.reason)
                if let draft = initiative.draft, !draft.isEmpty {
                    DisclosureGroup(t("Draft ready to review", "Bozza pronta da rivedere")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(draft).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Button(t("Copy draft", "Copia bozza")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(draft, forType: .string)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                DisclosureGroup(t("Why this suggestion", "Perché questo suggerimento")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(initiative.quote).textSelection(.enabled)
                        Text(initiative.app + " · " + initiative.window).font(.caption).foregroundStyle(.secondary)
                        Text(Date(timeIntervalSince1970: initiative.sourceTs), style: .relative).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button(t("Prepare with me", "Prepara con me")) { workspace.respond(initiative, response: "prepare") }
                    Button(t("In an hour", "Tra un’ora")) { workspace.respond(initiative, response: "snooze") }
                    Button(t("Not useful", "Non è utile")) { workspace.respond(initiative, response: "dismiss") }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
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
                    hint(t("I haven't observed your work yet. Grant macOS permissions so I can read the apps you use.", "Non ho ancora osservato il tuo lavoro. Concedi i permessi macOS per leggere le app che usi."))
                }
            }
            hint(t("Each Bobb has its own assignments. Your apps, browser and desktop are shared one task at a time.", "Ogni Bobb ha i suoi incarichi. Le tue app, il browser e lo schermo sono condivisi, un incarico alla volta."))
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
                hint(t("Bobb discovers this Mac's apps automatically. Allow reading and use, or exclude an app. Sending, payments, deletion and publishing ask by default. Password managers and secure fields stay protected.", "Bobb scopre automaticamente le app del Mac. Puoi consentire lettura e uso oppure escludere un’app. Invio, pagamenti, eliminazione e pubblicazione chiedono conferma di default. Gestori di password e campi segreti restano protetti."))
                TextField(t("Find an app", "Cerca un’app"), text: $appFilter)
                ForEach(boundaryApps) { app in
                    let protected = ScreenMemoryPolicy(extraProtected: state.settings.extraProtectedApps).isProtected(bundleId: app.id, appName: app.name)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(app.name).bold()
                                Spacer()
                                if protected {
                                    Label(t("Protected", "Protetta"), systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Toggle(t("Read and use", "Leggi e usa"), isOn: Binding(get: {
                                        state.settings.bobb.boundaries.app(bundleId: app.id, name: app.name) != nil
                                    }, set: { allowed in setAppAccess(app, allowed: allowed) }))
                                    .toggleStyle(.switch).fixedSize()
                                }
                            }
                            if !protected, state.settings.bobb.boundaries.app(bundleId: app.id, name: app.name) != nil {
                                DisclosureGroup(t("Action permissions", "Permessi delle azioni")) {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300))], alignment: .leading) {
                                        ForEach(ActionCategory.allCases, id: \.rawValue) { category in
                                            Picker(categoryName(category), selection: Binding(get: {
                                                state.settings.bobb.boundaries.app(bundleId: app.id, name: app.name)?.mode(category) ?? .deny
                                            }, set: { value in setAppMode(app, category: category, mode: value) })) {
                                                ForEach(BoundaryMode.allCases, id: \.rawValue) { mode in Text(modeName(mode)).tag(mode) }
                                            }
                                        }
                                    }
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
    private var boundaryApps: [AppBoundary] {
        var apps: [String: AppBoundary] = [:]
        for app in discoveredApps + [AppBoundary(id: "bobb.browser", name: "Bobb Browser")] + state.settings.bobb.boundaries.apps {
            apps[app.id] = app
        }
        for config in state.settings.bobb.connectors {
            let id = "mcp:\(config.id)"
            if apps[id] == nil { apps[id] = AppBoundary(id: id, name: "MCP \(config.id)") }
        }
        return apps.values.filter { appFilter.isEmpty || $0.name.localizedCaseInsensitiveContains(appFilter) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private func setAppAccess(_ app: AppBoundary, allowed: Bool) {
        workspace.coordinator.updateSettings { settings in
            settings.bobb.boundaries.excludedApps.removeAll { $0 == app.id || $0 == app.name }
            if allowed {
                if app.id.hasPrefix("mcp:") || app.id.hasPrefix("web:"), !settings.bobb.boundaries.apps.contains(where: { $0.id == app.id }) {
                    settings.bobb.boundaries.apps.append(app)
                }
            } else {
                settings.bobb.boundaries.excludedApps.append(app.id)
            }
        }
    }
    private func setAppMode(_ app: AppBoundary, category: ActionCategory, mode: BoundaryMode) {
        workspace.coordinator.updateSettings { settings in
            if let i = settings.bobb.boundaries.apps.firstIndex(where: { $0.id == app.id }) {
                settings.bobb.boundaries.apps[i].actions[category.rawValue] = mode
            } else {
                var override = app; override.actions[category.rawValue] = mode
                settings.bobb.boundaries.apps.append(override)
            }
        }
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
                    Text(t("Your browser", "Il tuo browser")).tag("browser"); Text(t("Mac desktop", "Schermo del Mac")).tag("desktop"); Text("MCP").tag("mcp")
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
                hint(t("Standing assignments run while this Mac is awake, Bobb is open, and background work is enabled. Desktop work waits until you are away. On Macs with up to 16 GB RAM, one background task runs at a time.", "Gli incarichi partono quando il Mac è sveglio, Bobb è aperto e il lavoro in background è attivo. Il lavoro sullo schermo aspetta che tu sia assente. Sui Mac con fino a 16 GB di RAM parte un solo incarico in background alla volta."))
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
                        if execution.run.surface == "browser" { Button(t("Show browser", "Mostra browser")) { workspace.inspectBrowser(agentId: execution.run.agentId) } }
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
                hint(t("Qwen writes locally; Kev makes decisions. The default models are quantized; 16 GB Macs run one task at a time. You can select another downloaded MLX checkpoint for writing.", "Qwen scrive in locale; Kev prende le decisioni. I modelli predefiniti sono quantizzati; sui Mac da 16 GB lavora un incarico alla volta. Puoi scegliere un altro checkpoint MLX già scaricato per la scrittura."))
                Text(state.settings.bobb.localModelPath.isEmpty ? "Qwen3.5 4B · MLX 4-bit" : state.settings.bobb.localModelPath).font(.caption).textSelection(.enabled)
                HStack { Button(t("Choose checkpoint…", "Scegli modello…"), action: chooseModel)
                    Button(t("Use default", "Usa predefinito")) { workspace.coordinator.updateSettings { $0.bobb.localModelPath = "" } }
                }
            }
            hint(t("Bobb speaks only when you talk to it using the microphone. Typed requests, suggestions and assignments stay silent.", "Bobb parla solo quando gli parli con il microfono. Le richieste scritte, i suggerimenti e gli incarichi restano silenziosi."))
        }.formStyle(.grouped)
    }
    private func chooseModel() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = false
        guard picker.runModal() == .OK, let url = picker.url, FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path) else { return }
        workspace.coordinator.updateSettings { $0.bobb.localModelPath = url.path }
    }

    private var computers: some View {
        Form {
            Section(t("Your browser", "Il tuo browser")) {
                Button(t("Open your browser", "Apri il tuo browser")) { workspace.inspectBrowser(agentId: workspace.activeAgent.id) }
                hint(t("Bobb uses your usual browser and its signed-in accounts. Browser work shares the desktop with your other apps.", "Bobb usa il browser abituale e gli account già aperti. Gli incarichi nel browser condividono il desktop con le altre app."))
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
                hint(t("Apple silicon, 24 GB RAM, a local macOS IPSW and a separate 64 GB sparse disk. Install Bobb in the guest, grant Accessibility, review its app exclusions and configure Remote Login with a dedicated SSH key. Verify its SSH fingerprint before connecting. No shared folders or forwarded credentials.", "Apple silicon, 24 GB di RAM, un IPSW macOS locale e un disco sparso separato da 64 GB. Installa Bobb nel guest, concedi Accessibilità, controlla le esclusioni delle app e configura Login remoto con una chiave SSH dedicata. Verifica prima l’impronta SSH. Nessuna cartella condivisa o credenziale inoltrata."))
                TextField(t("Guest private IPv4 address", "Indirizzo IPv4 privato del guest"), text: $guestAddress)
                TextField(t("Guest account", "Account del guest"), text: $guestUser)
                HStack {
                    Button(t("Choose SSH identity…", "Scegli identità SSH…")) {
                        let picker = NSOpenPanel(); picker.canChooseDirectories = false
                        if picker.runModal() == .OK { guestKey = picker.url?.path ?? "" }
                    }
                    Text(guestKey.isEmpty ? t("No key selected", "Nessuna chiave scelta") : URL(fileURLWithPath: guestKey).lastPathComponent).font(.caption)
                    Spacer()
                    Button(t("Connect virtual Mac", "Collega Mac virtuale"), action: connectGuest)
                }
                hint(t("Select the virtual-mac connector for an assignment. Host and guest boundaries both apply. An action that asks in the guest remains blocked until you review that category there.", "Seleziona il connettore virtual-mac per un incarico. Valgono i confini sia del Mac principale sia del guest. Un’azione che chiede nel guest resta bloccata finché rivedi lì quella categoria."))
            }
        }.formStyle(.grouped)
    }

    private func connectGuest() {
        let octets = guestAddress.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, guestAddress.split(separator: ".").count == 4,
              octets.allSatisfy({ (0...255).contains($0) }),
              octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 172 && (16...31).contains(octets[1])),
              !guestUser.isEmpty, guestUser.count <= 64, guestUser.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
              !guestUser.hasPrefix("-"), guestKey.hasPrefix("/"), FileManager.default.fileExists(atPath: guestKey) else {
            workspace.message = t("Enter a private IPv4 address, an account and a dedicated SSH key.", "Inserisci un IPv4 privato, un account e una chiave SSH dedicata."); return
        }
        let config = MCPConfiguration(id: "virtual-mac", executable: "/usr/bin/ssh", arguments: [
            "-T", "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no",
            "-o", "ConnectTimeout=10", "-o", "IdentityAgent=none", "-i", guestKey,
            "--", "\(guestUser)@\(guestAddress)", "/Applications/Bobb.app/Contents/MacOS/BobbApp --mcp-guest"
        ], enabled: true)
        workspace.coordinator.updateSettings { s in
            s.bobb.connectors.removeAll { $0.id == config.id }; s.bobb.connectors.append(config)
        }
        connect(id: "mcp:virtual-mac", name: "Virtual Mac")
    }
}
