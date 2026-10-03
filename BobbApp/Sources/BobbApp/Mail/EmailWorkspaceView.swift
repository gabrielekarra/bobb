import SwiftUI
import BobbCore

struct EmailWorkspaceView: View {
    @Bindable var workspace: EmailWorkspace
    @Bindable var state: AppState

    private func t(_ en: String, _ it: String) -> String { EmailCopy.t(en, it) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if workspace.syncing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(workspace.syncProgress.isEmpty ? t("Synchronizing…", "Sincronizzazione…") : workspace.syncProgress).font(.caption).lineLimit(1)
                    Spacer()
                    Button(t("Stop", "Ferma")) { workspace.stopSynchronization() }
                }.padding(.horizontal, 16).padding(.bottom, 10)
            }
            Divider()
            if !workspace.coordinator.permitsEmail {
                ContentUnavailableView(t("Mail is excluded", "Mail è esclusa"), systemImage: "lock",
                    description: Text(t("Enable Mail in Bobb’s Boundaries.", "Abilita Mail nei Confini di Bobb.")))
            } else {
                switch workspace.tab {
                case "reminders": reminders
                case "preferences": preferences
                default: messages
                }
            }
            if let error = state.emailError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).padding(10)
            } else if let notice = workspace.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary).padding(10)
            }
        }
        .tint(Theme.accent)
        .onChange(of: state.emailWriting?.text) { _, _ in workspace.syncText() }
        .onChange(of: state.emailWriting?.requestId) { _, _ in workspace.syncText() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            BobbMark(size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Email").font(.title3.bold())
                Text(t("Read, prepare, remember", "Leggi, prepara, ricorda")).font(.caption).foregroundStyle(.secondary)
            }
            Picker("", selection: $workspace.tab) {
                Text(t("Messages", "Messaggi")).tag("messages")
                Text(t("Reminders", "Promemoria") + " (\(state.email?.reminders.count ?? 0))").tag("reminders")
                Text(t("Preferences", "Preferenze")).tag("preferences")
            }.pickerStyle(.segmented).frame(maxWidth: 390)
                .onChange(of: workspace.tab) { _, value in if value == "preferences" { workspace.loadPreferences() } }
            Spacer()
            Button(t("Read selected email", "Leggi email selezionata")) { workspace.readCurrent() }
                .disabled(!workspace.coordinator.permitsEmail || workspace.writing)
            Button { Task { await workspace.synchronize() } } label: {
                if workspace.syncing { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.triangle.2.circlepath") }
            }
            .help(t("Synchronize all accounts and folders in Mail", "Sincronizza tutti gli account e le cartelle di Mail"))
            .disabled(workspace.syncing || !state.settings.memoryEnabled || !workspace.coordinator.permitsEmail)
        }.padding(16)
    }

    private var messages: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                TextField(t("Search sender, subject or content", "Cerca mittente, oggetto o contenuto"), text: $workspace.query)
                    .textFieldStyle(.roundedBorder).onSubmit { Task { await workspace.refresh() } }
                Picker(t("Show", "Mostra"), selection: $workspace.view) {
                    Text(t("All", "Tutte")).tag("all")
                    Text(t("To reply", "Da rispondere") + " (\(state.email?.counts["reply"] ?? 0))").tag("reply")
                    Text(t("Waiting for a reply", "In attesa di risposta")).tag("waiting")
                    Text(t("Unread", "Non lette")).tag("unread")
                    Text("VIP").tag("vip")
                    Text(t("Sent", "Inviate")).tag("sent")
                    Text(t("Received", "Ricevute")).tag("received")
                    Text(t("With attachments", "Con allegati")).tag("attachments")
                    Text(t("Flagged", "Contrassegnate")).tag("flagged")
                    Text(t("Handled", "Gestite")).tag("done")
                }.onChange(of: workspace.view) { _, _ in Task { await workspace.refresh() } }
                Picker(t("Account", "Account"), selection: $workspace.account) {
                    Text(t("All accounts", "Tutti gli account")).tag("")
                    ForEach(state.email?.accounts ?? [], id: \.self) { Text($0).tag($0) }
                }.onChange(of: workspace.account) { _, _ in Task { await workspace.refresh() } }
                Picker(t("Folder", "Cartella"), selection: $workspace.mailbox) {
                    Text(t("All folders", "Tutte le cartelle")).tag("")
                    ForEach(state.email?.mailboxes ?? [], id: \.self) { Text($0).tag($0) }
                }.onChange(of: workspace.mailbox) { _, _ in Task { await workspace.refresh() } }
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(workspace.items) { item in
                            Button { workspace.select(item.id) } label: { messageRow(item) }
                                .buttonStyle(.plain)
                        }
                        if state.email?.hasMore == true {
                            Button(t("Load more", "Carica altre")) { Task { await workspace.loadMore() } }
                                .disabled(workspace.loadingMore)
                        }
                    }
                }
                Text("\(workspace.items.count) / \(state.email?.total ?? workspace.items.count)").font(.caption).foregroundStyle(.secondary)
                if workspace.items.isEmpty {
                    Text(t("Read an email in Mail or synchronize to begin.", "Leggi un’email in Mail o sincronizza per iniziare."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text(state.settings.memoryEnabled
                     ? t("Synchronize to import all Mail accounts and folders. New inbox and sent messages update in the background.", "Sincronizza per importare tutti gli account e le cartelle di Mail. Le nuove email in arrivo e inviate si aggiornano in background.")
                     : t("Memory is off. You can still work on the selected email.", "Memoria disattivata. Puoi comunque lavorare sull’email selezionata."))
                    .font(.caption2).foregroundStyle(.tertiary)
                Button(t("Inbox brief", "Riepilogo inbox")) { workspace.generate("digest") }
                    .disabled(workspace.writing || workspace.items.isEmpty)
            }.padding(12).frame(minWidth: 230, idealWidth: 270, maxWidth: 330)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let selected = workspace.selected { reader(selected) }
                    else {
                        Text(t("Select an email, or write a new one.", "Seleziona un’email o scrivine una nuova."))
                            .foregroundStyle(.secondary).padding(.vertical, 14)
                    }
                    writingTools
                    if state.emailWriting != nil { resultEditor }
                }.padding(18)
            }.frame(minWidth: 560)
        }
    }

    private func messageRow(_ item: EmailItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(item.priority >= 3 ? Color.orange : item.priority == 2 ? Theme.accent : Color.secondary.opacity(0.25)).frame(width: 6, height: 6)
                Text(item.direction == "sent" ? t("To: ", "A: ") + item.to : item.sender).font(.caption).lineLimit(1)
                Spacer()
                if item.unread { Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(Theme.accent) }
                if item.flagged == true { Image(systemName: "flag.fill").font(.caption2).foregroundStyle(.orange) }
            }
            Text(item.subject.isEmpty ? t("No subject", "Senza oggetto") : item.subject).font(.callout.weight(.medium)).lineLimit(2)
            Text(String(MailScriptFormat.newestPart(of: item.body).prefix(120))).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let due = item.due {
                Label(Date(timeIntervalSince1970: due).formatted(date: .abbreviated, time: .shortened), systemImage: "clock").font(.caption2).foregroundStyle(.orange)
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(workspace.selectedId == item.id ? Theme.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
    }

    private func reader(_ item: EmailItem) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                Text(item.subject.isEmpty ? t("No subject", "Senza oggetto") : item.subject).font(.title3.bold()).textSelection(.enabled)
                Spacer()
                Button(t("Open in Mail", "Apri in Mail")) { workspace.original() }
                Menu(t("Manage in Mail", "Gestisci in Mail")) {
                    Button(t("Mark read", "Segna letta")) { workspace.changeInMail("read") }
                    Button(t("Mark unread", "Segna non letta")) { workspace.changeInMail("unread") }
                    Button(t("Flag", "Contrassegna")) { workspace.changeInMail("flag") }
                    Button(t("Remove flag", "Rimuovi contrassegno")) { workspace.changeInMail("unflag") }
                }.disabled(workspace.writing || !workspace.coordinator.permitsEmailAction(.write, context: item.subject))
            }
            Text(item.direction == "sent" ? t("To: ", "A: ") + item.to : item.sender).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            if !item.cc.isEmpty { Text("Cc: " + item.cc).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text(Date(timeIntervalSince1970: item.sentAt).formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                if item.needsReply && item.status == "open" { Label(t("Reply requested", "Risposta richiesta"), systemImage: "arrowshape.turn.up.left").font(.caption) }
                if item.status != "open" { Label(t("Handled", "Gestita"), systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
            }
            if let account = item.account, !account.isEmpty { Text(account + " · " + item.mailbox).font(.caption).foregroundStyle(.secondary) }
            if item.body.count >= 64000 { Text(t("Long message: the imported text is limited to 64,000 characters.", "Messaggio lungo: il testo importato è limitato a 64.000 caratteri.")).font(.caption).foregroundStyle(.orange) }
            if !item.attachments.isEmpty {
                Text(t("Attachments: ", "Allegati: ") + item.attachments.joined(separator: ", ")).font(.caption).textSelection(.enabled)
            }
            DisclosureGroup(t("Message content", "Contenuto del messaggio")) {
                Text(item.body).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
            if !item.evidence.isEmpty {
                Text(t("Priority signals: ", "Segnali di priorità: ") + item.evidence.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
            HStack {
                Button(t("Summarize thread", "Riassumi thread")) { workspace.generate("summary") }
                Button(t("Requests & deadlines", "Richieste e scadenze")) { workspace.generate("actions") }
                Menu(t("Remember", "Ricorda")) {
                    Button(t("Tomorrow", "Domani")) { workspace.remind(days: 1) }
                    Button(t("In 3 days", "Tra 3 giorni")) { workspace.remind(days: 3) }
                    Button(t("In a week", "Tra una settimana")) { workspace.remind(days: 7) }
                }.disabled(!state.settings.memoryEnabled)
                Button(item.status == "open" ? t("Mark handled", "Segna gestita") : t("Reopen", "Riapri")) {
                    workspace.status(item.status == "open" ? "done" : "open")
                }.disabled(!state.settings.memoryEnabled)
            }.disabled(workspace.writing)
            Divider()
        }
    }

    private var writingTools: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(t("Your instruction or question", "La tua istruzione o domanda")).font(.callout.bold())
                Spacer()
                if workspace.writing {
                    ProgressView().controlSize(.mini)
                    Button(t("Stop", "Ferma")) { workspace.coordinator.cancelEmailWriting() }
                }
            }
            TextField(t("e.g. Ask for the delivery date, politely", "es. Chiedi gentilmente la data di consegna"), text: $workspace.instruction, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)
            HStack {
                Menu(t("Write", "Scrivi")) {
                    Button(t("Reply draft", "Bozza di risposta")) { workspace.generate("reply") }.disabled(workspace.selected?.direction != "received")
                    Button(t("Reply to all", "Rispondi a tutti")) { workspace.generate("reply", kind: "replyall") }.disabled(workspace.selected?.direction != "received")
                    Button(t("Follow-up", "Sollecito")) { workspace.generate("followup") }.disabled(workspace.selected?.direction != "sent")
                    Button(t("Forward introduction", "Introduzione per inoltro")) { workspace.generate("forward") }.disabled(workspace.selected == nil)
                    Button(t("New email", "Nuova email")) { workspace.generate("new") }
                }
                Button(t("Answer my question", "Rispondi alla domanda")) { workspace.generate("questions") }.disabled(workspace.selected == nil)
                Button(t("Meeting notes", "Note per riunione")) { workspace.generate("meeting") }.disabled(workspace.selected == nil)
            }.disabled(workspace.writing)
            HStack {
                Picker(t("Translate into", "Traduci in"), selection: $workspace.translation) {
                    ForEach(["English", "Italian", "French", "German", "Spanish", "Portuguese"], id: \.self) { Text($0).tag($0) }
                }.frame(width: 155)
                Button(t("Translate", "Traduci")) { workspace.generate("translate") }.disabled(workspace.selected == nil && workspace.text.isEmpty)
            }.disabled(workspace.writing)
            if workspace.selected?.direction == "received" {
                HStack {
                    Button(t("Accept", "Accetta")) { workspace.generate("reply", instruction: "accept") }
                    Button(t("Decline", "Declina")) { workspace.generate("reply", instruction: "decline") }
                    Button(t("Need time", "Serve tempo")) { workspace.generate("reply", instruction: "more_time") }
                    Button(t("Ask for details", "Chiedi dettagli")) { workspace.generate("reply", instruction: "ask_details") }
                }.disabled(workspace.writing)
            }
        }
    }

    private var resultEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(workspace.isBody ? t("Editable draft", "Bozza modificabile") : t("Bobb’s notes", "Note di Bobb")).font(.headline)
            TextEditor(text: Binding(get: { workspace.text }, set: { workspace.text = $0; workspace.edited = true }))
                .font(.body).frame(height: 180).disabled(workspace.writing)
                .padding(8).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            if let unsupported = workspace.output?.unsupported, !unsupported.isEmpty, !workspace.edited {
                Text(t("Check these details: ", "Verifica questi dettagli: ") + unsupported.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.orange)
            }
            if workspace.output?.reviewNotes?.isEmpty == false, !workspace.edited {
                Text(t("Some details needed correction. Review whether this reply expresses what you want to say.", "Alcuni dettagli richiedevano una correzione. Controlla che la risposta esprima ciò che vuoi dire."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if workspace.isBody {
                HStack {
                    Button(t("Shorter", "Più breve")) { workspace.generate("rewrite", instruction: "Make this draft shorter, retaining its factual meaning.") }
                    Button(t("Warmer", "Più cordiale")) { workspace.generate("rewrite", instruction: "Make this draft warmer, without changing its meaning.") }
                    Button(t("More formal", "Più formale")) { workspace.generate("rewrite", instruction: "Make this draft more formal, without changing its meaning.") }
                    Button(t("Correct grammar", "Correggi grammatica")) { workspace.generate("rewrite", instruction: "Correct spelling and grammar only.") }
                    Button(t("Apply instruction", "Applica istruzione")) { workspace.generate("rewrite") }
                }.disabled(workspace.writing)
                HStack {
                    TextField(t("Recipients for a new email", "Destinatari per nuova email"), text: $workspace.recipients).textFieldStyle(.roundedBorder)
                    TextField(t("Subject for a new email", "Oggetto per nuova email"), text: $workspace.subject).textFieldStyle(.roundedBorder)
                }
            }
            if !workspace.previousDrafts.isEmpty {
                Button(t("Restore previous version", "Ripristina versione precedente")) { workspace.undoRewrite() }.disabled(workspace.writing)
            }
            if let sources = workspace.output?.emailSources, !sources.isEmpty {
                DisclosureGroup(t("Source emails", "Email di origine")) {
                    ForEach(sources) { source in
                        Button("[\(source.n)] " + source.subject + " · " + source.sender) { workspace.show(messageId: source.messageId) }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Text(t("You review and send in Mail.", "Rivedi e invii tu da Mail.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(t("Copy", "Copia")) { Clipboard.copy(workspace.text); workspace.notice = t("Copied", "Copiato") }
                    .disabled(workspace.writing || workspace.text.isEmpty)
                if workspace.isBody {
                    Button(t("Open draft in Mail", "Apri bozza in Mail")) { workspace.openDraft() }
                        .buttonStyle(.borderedProminent)
                        .disabled(workspace.writing || workspace.text.isEmpty || workspace.output?.cancelled == true)
                }
            }
        }
    }

    private var reminders: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(t("Replies and follow-ups", "Risposte e follow-up")).font(.title3.bold())
                Text(t("Reminders are resolved when a matching reply is observed. Mail must be running for synchronization.", "I promemoria si chiudono quando viene osservata una risposta corrispondente. Mail deve essere aperta per la sincronizzazione."))
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(state.email?.reminders ?? []) { reminder in
                    HStack(spacing: 12) {
                        Image(systemName: reminder.kind == "waiting" ? "hourglass" : "clock").foregroundStyle(reminder.ready ? .orange : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(reminder.subject).font(.headline)
                            Text(reminder.kind == "waiting" ? t("Waiting for: ", "In attesa da: ") + reminder.to : reminder.sender).font(.caption).foregroundStyle(.secondary)
                            Text(Date(timeIntervalSince1970: reminder.due).formatted(date: .abbreviated, time: .shortened)).font(.caption)
                        }
                        Spacer()
                        Button(t("Prepare", "Prepara")) { workspace.tab = "messages"; workspace.show(messageId: reminder.messageId) }
                        Button(t("Tomorrow", "Domani")) { workspace.reminder(reminder, action: "snooze") }
                        Button(t("Done", "Fatto")) { workspace.reminder(reminder, action: "done") }
                        Button { workspace.reminder(reminder, action: "dismiss") } label: { Image(systemName: "xmark") }
                    }.padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                if state.email?.reminders.isEmpty != false {
                    Text(t("No pending reminders. Choose Remember on an email.", "Nessun promemoria in sospeso. Scegli Ricorda su un’email."))
                        .foregroundStyle(.secondary).padding(.vertical, 20)
                }
            }.padding(24)
        }
    }

    private var preferences: some View {
        Form {
            Text(t("Your email preferences", "Le tue preferenze email")).font(.title3.bold())
            TextField(t("VIP senders (comma-separated email addresses)", "Mittenti VIP (indirizzi email separati da virgole)"), text: $workspace.vipText)
            Picker(t("Writing style", "Stile di scrittura"), selection: $workspace.style) {
                Text(t("Concise", "Conciso")).tag("concise")
                Text(t("Warm", "Cordiale")).tag("warm")
                Text(t("Formal", "Formale")).tag("formal")
            }
            Text(t("Signature", "Firma"))
            TextEditor(text: $workspace.signature).frame(height: 90)
            Text(t("Drafts use your chosen style and signature. Translation and rewrites preserve your edited text.", "Le bozze usano stile e firma scelti. Traduzioni e riscritture conservano il testo che hai modificato."))
                .font(.caption).foregroundStyle(.secondary)
            Button(t("Save", "Salva")) { workspace.savePreferences() }.buttonStyle(.borderedProminent)
            Toggle(t("Keep the full imported archive", "Conserva l’archivio completo importato"), isOn: $workspace.archiveAll)
            Text(t("Full archive import keeps older emails searchable until you forget them. Disable this and save to apply general memory retention.", "L’importazione completa conserva ricercabili anche le email più vecchie finché non le rimuovi. Disattiva e salva per applicare la conservazione generale della memoria."))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(t("Draft automatically when I click Reply in Mail", "Prepara la bozza automaticamente quando clicco Rispondi in Mail"), isOn: Binding(get: { state.settings.mailInlineReplies }, set: { value in workspace.coordinator.updateSettings { $0.mailInlineReplies = value } }))
            Toggle(t("Proactive email help", "Aiuto proattivo email"), isOn: Binding(get: { state.settings.mailProactive }, set: { value in workspace.coordinator.updateSettings { $0.mailProactive = value } }))
            Toggle(t("Draft checks and tone", "Controlli bozza e tono"), isOn: Binding(get: { state.settings.toneCheck }, set: { value in workspace.coordinator.updateSettings { $0.toneCheck = value } }))
            Text(t("Quiet hours, app exclusions, memory and history retention use Bobb’s general settings.", "Ore di silenzio, app escluse, memoria e conservazione della cronologia usano le impostazioni generali di Bobb."))
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped).padding(16)
    }
}
