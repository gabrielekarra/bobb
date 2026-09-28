import Foundation

/// The UI language. `system` follows macOS's preferred languages, falling
/// back to English for anything that is not Italian.
public enum AppLanguage: String, Codable, Sendable, CaseIterable {
    case system, en, it

    public var code: String {
        switch self {
        case .en: return "en"
        case .it: return "it"
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            return preferred.hasPrefix("it") ? "it" : "en"
        }
    }
}

/// Every string a person reads in the app, in English and Italian.
///
/// A table in code rather than `.strings` files: the app is assembled
/// without Xcode (ADR-003), and resource bundles from an executable target
/// do not survive being copied into a hand-built `.app`. A table also makes
/// a missing translation a compile-time impossibility — every key has both.
/// Placeholders are `{name}`, replaced by `t(_:_:)`.
public enum L10n {
    nonisolated(unsafe) public static var code: String = AppLanguage.system.code

    public static func t(_ key: Key, _ values: [String: String] = [:]) -> String {
        let pair = table[key] ?? (key.rawValue, key.rawValue)
        var text = code == "it" ? pair.1 : pair.0
        for (name, value) in values {
            text = text.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return text
    }

    public static func percent(_ p: Double) -> String {
        "\(Int((p * 100).rounded()))%"
    }

    public enum Key: String, CaseIterable, Sendable {
        // status
        case statusWatching, statusPaused, statusThinking, statusSuggesting, statusStarting, statusModelMissing,
             statusError, statusDisconnected, statusTrialExpired
        // menu bar
        case menuForYou, menuNothingForYou, menuAskPlaceholder, menuMind, menuMemory, menuSettings, menuQuit,
             menuPause, menuResume, menuOpenSetup, menuSilentToday, menuHelpedToday
        // overlay and suggestions
        case overlayIgnore, overlayPrepare, overlayWhy
        // draft panel
        case draftTitle, draftWriting, draftCopy, draftCopied, draftInsert, draftOpenInMail, draftRegenerate,
             draftAccept, draftDecline, draftMoreTime, draftAskDetails, draftInstructionPlaceholder, draftClose,
             draftError, draftSources, draftNeverSent, draftInserted, draftPasteHint
        // command bar
        case askPlaceholder, askPlaceholderSelection, askSelectionLabel, askModeAsk, askModeWrite, askModeReply,
             askModeRewrite, askModeTranslate, askModeSummarize, askModeExplain, askReplace, askCopy, askInsert,
             askStop, askNoMemory, askWorking, askHint, askSources, askNotReady, askError
        // mind
        case mindTitle, mindToday, mindDecisions, mindSilences, mindSuggested, mindAccepted, mindLatency,
             mindSilentShare, mindFloor, mindFloorHint, mindHideSignals, mindEmpty, mindWaiting, mindNearMiss,
             mindLearned, mindLearnedEmpty, mindMutedSender, mindForget, mindPersonalFloor, mindEvent, mindHypotheses,
             mindReadouts, mindTechnical, mindConnected, mindWatch
        // memory window
        case memoryTitle, memorySearch, memoryEmpty, memoryRows, memoryDelete, memoryDeleteApp, memoryDeleteAll,
             memoryDeleteAllConfirm, memoryDeleteAllBody, memoryDeleteLastHour, memoryDeleteToday, memoryApps,
             memoryPaused, memoryPrivacyNote, memoryRecent, memoryCancel, memoryDeleted
        // settings
        case settingsTitle, settingsGeneral, settingsAttention, settingsPrivacy, settingsModel, settingsLicense,
             settingsAbout, settingsLanguage, settingsLanguageSystem, settingsLaunchAtLogin, settingsHotkey,
             settingsHotkeyHint, settingsMailProactive, settingsMailProactiveHint, settingsToneCheck,
             settingsToneCheckHint, settingsFloor, settingsFloorHint, settingsAdaptive, settingsAdaptiveHint,
             settingsQuietHours, settingsQuietFrom, settingsQuietTo, settingsOverlaySeconds, settingsMemoryEnabled,
             settingsMemoryEnabledHint, settingsMemoryRetention, settingsHistoryRetention, settingsDays,
             settingsProtectedApps, settingsProtectedAppsHint, settingsAddApp, settingsRemove, settingsOpenMemory,
             settingsDeleteHistory, settingsDeleteHistoryConfirm, settingsNetworkTitle, settingsNetworkBody,
             settingsPermissions, settingsAccessibility, settingsAutomation, settingsGranted, settingsNotGranted,
             settingsOpenSystemSettings, settingsModelInstalled, settingsModelMissing, settingsModelVerify,
             settingsModelVerifying, settingsModelOK, settingsModelCorrupt, settingsModelLocation, settingsModelName, settingsModelLicense,
             settingsModelReveal, settingsDaemonRestart, settingsExportDiagnostics, settingsCheckUpdates,
             settingsVersion, settingsBuiltWithLlama, settingsThirdParty
        // license
        case licenseTrial, licenseTrialExpired, licenseLicensed, licenseUpdatesExpired, licenseEnter,
             licensePlaceholder, licenseActivate, licenseInvalid, licenseBuy, licenseEdition, licenseUpdatesUntil,
             licenseRemove, licenseDevBuild, licenseExpiredBody
        // onboarding
        case onbWelcomeTitle, onbWelcomeBody, onbContinue, onbBack, onbSkip, onbDone, onbPrivacyTitle,
             onbPrivacy1, onbPrivacy2, onbPrivacy3, onbPrivacy4, onbPermissionsTitle, onbPermissionsBody,
             onbAccessibilityWhy, onbAutomationWhy, onbGrant, onbGranted, onbModelTitle, onbModelBody,
             onbDownload, onbDownloading, onbVerifying, onbModelReady, onbModelFailed, onbRetry,
             onbModelOffline, onbReadyTitle, onbReadyBody, onbTryIt, onbHotkeyTip
        // chart and audit
        case chartTitle, chartWouldSurface, chartSilent, chartNearMiss, chartThreshold, readoutMass, readoutCloseTo, auditTitle, auditSearch, auditSelect, auditRawEvent,
             auditOpen
        // tasks
        case askModeDo, askPlaceholderDo, taskPlanning, taskLooking, taskPressing, taskTyping, taskScrolling,
             taskOpening, taskWaiting, taskStop, taskUndo, taskDone, taskStopped, taskBlocked, taskFailed,
             taskAskPress, taskAskType, taskAskTypeSubmit, taskAskScroll, taskAskOpen, taskAllow, taskAllowAlways,
             taskPlanTitle, taskStepsTitle, taskEscHint, taskNotTrusted, taskDisabled, taskEngine, taskProtected,
             taskSecure, taskTooManySteps, taskKeptLoading, taskAppDidNotRespond, taskNotSure, taskNothingFits,
             taskStuck, reasonSends, reasonPays, reasonDeletes, reasonPublishes, reasonSigns, reasonRunsCommand,
             reasonSendsMessage, reasonClosesWithoutSaving, reasonEveryStep, settingsActing, settingsActingEnabled,
             settingsActingHint, settingsActingApproval, settingsApprovalImportant, settingsApprovalEvery,
             settingsAllowRules, settingsAllowRulesEmpty, mindTasks, mindTasksEmpty, mindTaskSteps
        // specialist
        case mindSpecialist, mindSpecialistLearning, mindSpecialistChecking, mindSpecialistActive,
             mindSpecialistAgreement, mindSpecialistAlone, mindSpecialistBadge
        // chats
        case settingsChatProactive, settingsChatProactiveHint
        // promises
        case promiseDone, promiseTomorrow, promiseNotAPromise, promiseTo, promiseToDue, promiseOverdue, promiseToday,
             promiseTomorrowDue, settingsCalendar, settingsCalendarAllow, settingsMeetingPrep,
             settingsMeetingPrepHint, settingsTrackPromises, settingsTrackPromisesHint
        // voice
        case voiceListening, voiceTalk, voiceNotAllowed, voiceNoMicrophone, voiceUnavailable, voiceNotOnDevice,
             settingsTalkHotkey
        // ocr
        case settingsReadImages, settingsReadImagesHint
        // showme
        case taskShowMe, taskWatching, taskWatchDone, taskLearned
        // misc
        case genericCancel, genericDelete, genericOK, genericClose, genericError, relToday, relYesterday, relDaysAgo,
             relMinutesAgo, relJustNow, relHoursAgo
    }

    // swiftlint:disable line_length
    static let table: [Key: (String, String)] = [
        .statusWatching: ("Watching quietly", "Osservo in silenzio"),
        .statusPaused: ("Paused", "In pausa"),
        .statusThinking: ("Thinking…", "Sto pensando…"),
        .statusSuggesting: ("I have a suggestion", "Ho un suggerimento"),
        .statusStarting: ("Starting up…", "Mi sto avviando…"),
        .statusModelMissing: ("Setup needed", "Configurazione necessaria"),
        .statusError: ("Something went wrong", "Qualcosa è andato storto"),
        .statusDisconnected: ("Leonard's engine is not running", "Il motore di Leonard non è attivo"),
        .statusTrialExpired: ("Trial ended", "Prova terminata"),

        .menuForYou: ("For you", "Per te"),
        .menuNothingForYou: ("Nothing needs you right now.", "Niente richiede la tua attenzione."),
        .menuAskPlaceholder: ("Ask Leonard…", "Chiedi a Leonard…"),
        .menuMind: ("Mind", "Mind"),
        .menuMemory: ("Memory", "Memoria"),
        .menuSettings: ("Settings…", "Impostazioni…"),
        .menuQuit: ("Quit Leonard", "Esci da Leonard"),
        .menuPause: ("Pause", "Pausa"),
        .menuResume: ("Resume", "Riprendi"),
        .menuOpenSetup: ("Finish setup", "Completa la configurazione"),
        .menuSilentToday: ("{count} times quiet", "{count} volte in silenzio"),
        .menuHelpedToday: ("{count} suggestions", "{count} suggerimenti"),

        .overlayIgnore: ("Ignore", "Ignora"),
        .overlayPrepare: ("Prepare", "Prepara"),
        .overlayWhy: ("Why?", "Perché?"),

        .draftTitle: ("Draft", "Bozza"),
        .draftWriting: ("Writing on your Mac…", "Scrivo sul tuo Mac…"),
        .draftCopy: ("Copy", "Copia"),
        .draftCopied: ("Copied", "Copiato"),
        .draftInsert: ("Insert", "Inserisci"),
        .draftOpenInMail: ("Reply in Mail", "Rispondi in Mail"),
        .draftRegenerate: ("Rewrite", "Riscrivi"),
        .draftAccept: ("Accept", "Accetta"),
        .draftDecline: ("Decline", "Declina"),
        .draftMoreTime: ("Need time", "Serve tempo"),
        .draftAskDetails: ("Ask for details", "Chiedi dettagli"),
        .draftInstructionPlaceholder: ("Or say how to change it…", "Oppure di' come cambiarla…"),
        .draftClose: ("Close", "Chiudi"),
        .draftError: ("Leonard couldn't write this one.", "Leonard non è riuscito a scriverla."),
        .draftSources: ("Used", "Ha usato"),
        .draftNeverSent: ("Nothing is sent until you send it.", "Niente viene inviato finché non lo invii tu."),
        .draftInserted: ("Inserted", "Inserito"),
        .draftPasteHint: ("Copied — press ⌘V to paste", "Copiato — premi ⌘V per incollare"),

        .askPlaceholder: ("Ask about anything you've seen, or ask me to write", "Chiedi di qualsiasi cosa tu abbia visto, o fammi scrivere"),
        .askPlaceholderSelection: ("What should I do with the selection?", "Cosa faccio con la selezione?"),
        .askSelectionLabel: ("Selection from {app}", "Selezione da {app}"),
        .askModeAsk: ("Ask", "Chiedi"),
        .askModeWrite: ("Write", "Scrivi"),
        .askModeReply: ("Reply", "Rispondi"),
        .askModeRewrite: ("Improve", "Migliora"),
        .askModeTranslate: ("Translate", "Traduci"),
        .askModeSummarize: ("Summarize", "Riassumi"),
        .askModeExplain: ("Explain", "Spiega"),
        .askReplace: ("Replace selection", "Sostituisci selezione"),
        .askCopy: ("Copy", "Copia"),
        .askInsert: ("Insert", "Inserisci"),
        .askStop: ("Stop", "Ferma"),
        .askNoMemory: ("Nothing on your screen matched.", "Niente di ciò che hai visto corrisponde."),
        .askWorking: ("Thinking on your Mac…", "Ragiono sul tuo Mac…"),
        .askHint: ("↩ ask · ⇥ change mode · esc close", "↩ chiedi · ⇥ cambia modalità · esc chiudi"),
        .askSources: ("From your screen", "Dal tuo schermo"),
        .askNotReady: ("Leonard is still starting up.", "Leonard si sta ancora avviando."),
        .askError: ("Leonard couldn't answer: {detail}", "Leonard non è riuscito a rispondere: {detail}"),

        .mindTitle: ("Mind", "Mind"),
        .mindToday: ("Last 30 days", "Ultimi 30 giorni"),
        .mindDecisions: ("Decisions", "Decisioni"),
        .mindSilences: ("Stayed quiet", "Silenzi"),
        .mindSuggested: ("Spoke up", "Ha parlato"),
        .mindAccepted: ("Accepted", "Accettati"),
        .mindLatency: ("Median decision", "Decisione mediana"),
        .mindSilentShare: ("{percent} of decisions stayed silent", "Il {percent} delle decisioni è rimasto in silenzio"),
        .mindFloor: ("Interruption threshold", "Soglia di interruzione"),
        .mindFloorHint: ("Drag it: the chart shows at once what would have reached you.", "Spostala: il grafico mostra subito cosa ti sarebbe arrivato."),
        .mindHideSignals: ("Hide learning events", "Nascondi eventi di apprendimento"),
        .mindEmpty: ("Nothing yet. Leonard is watching.", "Ancora niente. Leonard sta osservando."),
        .mindWaiting: ("deciding…", "sto decidendo…"),
        .mindNearMiss: ("Almost spoke: {confidence} sure, below the {floor} threshold. Stayed quiet.", "Ha quasi parlato: sicuro al {confidence}, sotto la soglia del {floor}. È rimasto in silenzio."),
        .mindLearned: ("What Leonard has learned", "Cosa ha imparato Leonard"),
        .mindLearnedEmpty: ("Nothing yet. Leonard learns from how you answer its suggestions.", "Ancora niente. Leonard impara da come rispondi ai suoi suggerimenti."),
        .mindMutedSender: ("Stays quiet about {sender}", "Non ti disturba per {sender}"),
        .mindForget: ("Forget", "Dimentica"),
        .mindPersonalFloor: ("{kind}: threshold {floor} ({approved} accepted, {dismissed} ignored)", "{kind}: soglia {floor} ({approved} accettati, {dismissed} ignorati)"),
        .mindEvent: ("Event", "Evento"),
        .mindHypotheses: ("Intent hypotheses", "Ipotesi di intento"),
        .mindReadouts: ("Readouts", "Letture"),
        .mindTechnical: ("Technical trace", "Traccia tecnica"),
        .mindConnected: ("Running on your Mac · {model}", "In esecuzione sul tuo Mac · {model}"),
        .mindWatch: ("Watch", "Osserva"),

        .memoryTitle: ("Memory", "Memoria"),
        .memorySearch: ("Search everything you've seen", "Cerca in tutto ciò che hai visto"),
        .memoryEmpty: ("Nothing remembered yet.", "Ancora niente in memoria."),
        .memoryRows: ("{count} screens remembered", "{count} schermate ricordate"),
        .memoryDelete: ("Delete", "Elimina"),
        .memoryDeleteApp: ("Forget everything from {app}", "Dimentica tutto di {app}"),
        .memoryDeleteAll: ("Forget everything…", "Dimentica tutto…"),
        .memoryDeleteAllConfirm: ("Forget everything Leonard remembers?", "Dimenticare tutto ciò che Leonard ricorda?"),
        .memoryDeleteAllBody: ("This deletes every remembered screen from this Mac. It cannot be undone.", "Elimina da questo Mac ogni schermata ricordata. Non si può annullare."),
        .memoryDeleteLastHour: ("Forget the last hour", "Dimentica l'ultima ora"),
        .memoryDeleteToday: ("Forget today", "Dimentica oggi"),
        .memoryApps: ("Apps", "App"),
        .memoryPaused: ("Memory is off. Nothing new is being remembered.", "La memoria è spenta. Niente di nuovo viene ricordato."),
        .memoryPrivacyNote: ("Text only, never screenshots. Stored on this Mac, never uploaded. Password managers are never read.", "Solo testo, mai screenshot. Salvato su questo Mac, mai caricato. I password manager non vengono mai letti."),
        .memoryRecent: ("Recent", "Recenti"),
        .memoryCancel: ("Cancel", "Annulla"),
        .memoryDeleted: ("Forgot {count}", "Dimenticate {count}"),

        .settingsTitle: ("Leonard Settings", "Impostazioni di Leonard"),
        .settingsGeneral: ("General", "Generale"),
        .settingsAttention: ("Attention", "Attenzione"),
        .settingsPrivacy: ("Privacy", "Privacy"),
        .settingsModel: ("Model", "Modello"),
        .settingsLicense: ("License", "Licenza"),
        .settingsAbout: ("About", "Info"),
        .settingsLanguage: ("Language", "Lingua"),
        .settingsLanguageSystem: ("Same as macOS", "Come macOS"),
        .settingsLaunchAtLogin: ("Open Leonard at login", "Apri Leonard all'avvio"),
        .settingsHotkey: ("Ask Leonard shortcut", "Scorciatoia per Chiedi a Leonard"),
        .settingsHotkeyHint: ("Works in every app. With text selected, Leonard offers to rewrite, translate or reply.", "Funziona in ogni app. Con del testo selezionato, Leonard propone di migliorarlo, tradurlo o rispondere."),
        .settingsMailProactive: ("Tell me when an email needs me", "Avvisami quando una mail richiede me"),
        .settingsMailProactiveHint: ("Leonard reads the message you open in Mail and speaks up only when it's worth it.", "Leonard legge il messaggio che apri in Mail e interviene solo quando ne vale la pena."),
        .settingsToneCheck: ("Warn me before I send a harsh email", "Avvisami prima di inviare una mail brusca"),
        .settingsToneCheckHint: ("Checks the tone of drafts you're writing in Mail.", "Controlla il tono delle bozze che scrivi in Mail."),
        .settingsFloor: ("How sure Leonard must be before interrupting", "Quanto deve essere sicuro Leonard prima di interromperti"),
        .settingsFloorHint: ("Higher means quieter. {value} now.", "Più alta vuol dire più silenzio. Ora {value}."),
        .settingsAdaptive: ("Learn from my answers", "Impara dalle mie risposte"),
        .settingsAdaptiveHint: ("Leonard adjusts its threshold and mutes senders you always ignore. You can see and undo every rule in Mind.", "Leonard regola la soglia e silenzia i mittenti che ignori sempre. Vedi e annulli ogni regola in Mind."),
        .settingsQuietHours: ("Quiet hours", "Ore di silenzio"),
        .settingsQuietFrom: ("From", "Dalle"),
        .settingsQuietTo: ("to", "alle"),
        .settingsOverlaySeconds: ("Keep a suggestion on screen for", "Tieni un suggerimento sullo schermo per"),
        .settingsMemoryEnabled: ("Remember what's on my screen", "Ricorda cosa c'è sul mio schermo"),
        .settingsMemoryEnabledHint: ("Lets you ask about anything you've seen. Text only, stored on this Mac.", "Ti permette di chiedere di qualsiasi cosa tu abbia visto. Solo testo, salvato su questo Mac."),
        .settingsMemoryRetention: ("Forget screens after", "Dimentica le schermate dopo"),
        .settingsHistoryRetention: ("Forget decision history after", "Dimentica lo storico delle decisioni dopo"),
        .settingsDays: ("{count} days", "{count} giorni"),
        .settingsProtectedApps: ("Never read these apps", "Non leggere mai queste app"),
        .settingsProtectedAppsHint: ("Password managers, Keychain and System Settings are always protected. Add your banking or any other app.", "Password manager, Portachiavi e Impostazioni di Sistema sono sempre protetti. Aggiungi la tua banca o qualsiasi altra app."),
        .settingsAddApp: ("Add app…", "Aggiungi app…"),
        .settingsRemove: ("Remove", "Rimuovi"),
        .settingsOpenMemory: ("Browse and delete memory…", "Sfoglia ed elimina la memoria…"),
        .settingsDeleteHistory: ("Delete decision history…", "Elimina lo storico delle decisioni…"),
        .settingsDeleteHistoryConfirm: ("Delete every decision Leonard has recorded, and everything it learned from them?", "Eliminare ogni decisione registrata da Leonard e tutto ciò che ne ha imparato?"),
        .settingsNetworkTitle: ("Nothing leaves this Mac", "Niente esce da questo Mac"),
        .settingsNetworkBody: ("Leonard's engine has no network access by design: it cannot open a connection, and a test fails the build if it ever could. The only download is the model, once, when you approve it.", "Il motore di Leonard non ha accesso alla rete per costruzione: non può aprire una connessione, e un test blocca la build se mai potesse. L'unico download è il modello, una volta, quando lo approvi."),
        .settingsPermissions: ("Permissions", "Permessi"),
        .settingsAccessibility: ("Accessibility — to read the text on screen", "Accessibilità — per leggere il testo sullo schermo"),
        .settingsAutomation: ("Mail automation — to read messages and open replies", "Automazione di Mail — per leggere i messaggi e aprire le risposte"),
        .settingsGranted: ("Granted", "Concesso"),
        .settingsNotGranted: ("Not granted", "Non concesso"),
        .settingsOpenSystemSettings: ("Open System Settings", "Apri Impostazioni di Sistema"),
        .settingsModelInstalled: ("Installed · {size}", "Installato · {size}"),
        .settingsModelMissing: ("Not installed", "Non installato"),
        .settingsModelVerify: ("Verify integrity", "Verifica integrità"),
        .settingsModelVerifying: ("Verifying…", "Verifica in corso…"),
        .settingsModelOK: ("Every file matches its published checksum.", "Ogni file corrisponde al checksum pubblicato."),
        .settingsModelCorrupt: ("Some files are damaged. Download the model again.", "Alcuni file sono danneggiati. Scarica di nuovo il modello."),
        .settingsModelLocation: ("Location", "Posizione"),
        .settingsModelName: ("Model", "Modello"),
        .settingsModelLicense: ("License", "Licenza"),
        .settingsModelReveal: ("Show in Finder", "Mostra nel Finder"),
        .settingsDaemonRestart: ("Restart engine", "Riavvia il motore"),
        .settingsExportDiagnostics: ("Export diagnostics…", "Esporta diagnostica…"),
        .settingsCheckUpdates: ("Check for updates…", "Cerca aggiornamenti…"),
        .settingsVersion: ("Version {version}", "Versione {version}"),
        .settingsBuiltWithLlama: ("Built with Llama", "Built with Llama"),
        .settingsThirdParty: ("Third-party notices", "Note di terze parti"),

        .licenseTrial: ("Free trial · {days} days left", "Prova gratuita · {days} giorni rimasti"),
        .licenseTrialExpired: ("Your free trial has ended", "La prova gratuita è terminata"),
        .licenseLicensed: ("Licensed to {name}", "Licenza intestata a {name}"),
        .licenseUpdatesExpired: ("This version was released after your updates ended on {date}", "Questa versione è uscita dopo la fine dei tuoi aggiornamenti, il {date}"),
        .licenseEnter: ("Enter license key", "Inserisci la chiave di licenza"),
        .licensePlaceholder: ("Paste your license key", "Incolla la tua chiave di licenza"),
        .licenseActivate: ("Activate", "Attiva"),
        .licenseInvalid: ("That key isn't valid. Check you copied all of it.", "Questa chiave non è valida. Controlla di averla copiata tutta."),
        .licenseBuy: ("Buy Leonard…", "Acquista Leonard…"),
        .licenseEdition: ("Edition", "Edizione"),
        .licenseUpdatesUntil: ("Updates until {date}", "Aggiornamenti fino al {date}"),
        .licenseRemove: ("Remove license", "Rimuovi licenza"),
        .licenseDevBuild: ("Development build", "Build di sviluppo"),
        .licenseExpiredBody: ("Leonard still shows your memory and history, but it has stopped suggesting and answering. A license keeps it working forever.", "Leonard mostra ancora memoria e storico, ma ha smesso di suggerire e rispondere. Una licenza lo fa funzionare per sempre."),

        .onbWelcomeTitle: ("Meet Leonard", "Ti presento Leonard"),
        .onbWelcomeBody: ("An assistant that lives in your menu bar, reads what you read, and speaks up only when something needs you. Everything runs on this Mac.", "Un assistente che vive nella barra dei menu, legge quello che leggi e interviene solo quando qualcosa richiede te. Tutto gira su questo Mac."),
        .onbContinue: ("Continue", "Continua"),
        .onbBack: ("Back", "Indietro"),
        .onbSkip: ("Later", "Più tardi"),
        .onbDone: ("Start using Leonard", "Inizia a usare Leonard"),
        .onbPrivacyTitle: ("Private by architecture", "Privato per costruzione"),
        .onbPrivacy1: ("The AI runs on your Mac. No cloud, no account, no API key.", "L'intelligenza artificiale gira sul tuo Mac. Niente cloud, niente account, niente chiavi API."),
        .onbPrivacy2: ("Leonard's engine cannot connect to the internet. That's enforced by its design, not by a promise.", "Il motore di Leonard non può connettersi a internet. Lo garantisce il suo design, non una promessa."),
        .onbPrivacy3: ("It remembers text, never screenshots, and never reads password managers.", "Ricorda testo, mai screenshot, e non legge mai i password manager."),
        .onbPrivacy4: ("You can see, search and delete everything it knows.", "Puoi vedere, cercare ed eliminare tutto ciò che sa."),
        .onbPermissionsTitle: ("Two permissions", "Due permessi"),
        .onbPermissionsBody: ("macOS asks you to approve what Leonard can see. You can change this at any time in System Settings.", "macOS ti chiede di approvare cosa può vedere Leonard. Puoi cambiarlo quando vuoi in Impostazioni di Sistema."),
        .onbAccessibilityWhy: ("Accessibility lets Leonard read the text of the window in front of you, and insert what it writes.", "Accessibilità permette a Leonard di leggere il testo della finestra davanti a te e di inserire ciò che scrive."),
        .onbAutomationWhy: ("Mail automation lets Leonard read the message you open and prepare a reply in a new Mail window. It never sends anything.", "L'automazione di Mail permette a Leonard di leggere il messaggio che apri e preparare una risposta in una nuova finestra di Mail. Non invia mai nulla."),
        .onbGrant: ("Allow…", "Consenti…"),
        .onbGranted: ("Allowed", "Consentito"),
        .onbModelTitle: ("Download Leonard's brain", "Scarica il cervello di Leonard"),
        .onbModelBody: ("A 1.8 GB language model, downloaded once from Hugging Face and checked against its published checksum. After this, Leonard never goes online.", "Un modello linguistico da 1,8 GB, scaricato una volta da Hugging Face e verificato con il suo checksum pubblicato. Dopo, Leonard non va mai online."),
        .onbDownload: ("Download (1.8 GB)", "Scarica (1,8 GB)"),
        .onbDownloading: ("Downloading… {progress}", "Download… {progress}"),
        .onbVerifying: ("Checking integrity…", "Verifico l'integrità…"),
        .onbModelReady: ("Ready. Leonard is loading it now.", "Pronto. Leonard lo sta caricando."),
        .onbModelFailed: ("The download failed: {detail}", "Il download non è riuscito: {detail}"),
        .onbRetry: ("Try again", "Riprova"),
        .onbModelOffline: ("Installing offline? Put the model folder in {path}", "Installazione offline? Metti la cartella del modello in {path}"),
        .onbReadyTitle: ("You're set", "È tutto pronto"),
        .onbReadyBody: ("Keep working as usual. Leonard stays quiet until something needs you — and everything it decides is visible in Mind.", "Continua a lavorare come sempre. Leonard resta in silenzio finché qualcosa non richiede te — e ogni sua decisione è visibile in Mind."),
        .onbTryIt: ("Try it: select any text and press {hotkey}.", "Provalo: seleziona un testo e premi {hotkey}."),
        .onbHotkeyTip: ("Ask Leonard from anywhere with {hotkey}.", "Chiedi a Leonard da ovunque con {hotkey}."),

        .chartTitle: ("Confidence vs threshold", "Confidenza vs soglia"),
        .chartWouldSurface: ("would reach you", "ti arriverebbe"),
        .chartSilent: ("silent", "silenzio"),
        .chartNearMiss: ("near miss", "quasi emerso"),
        .chartThreshold: ("threshold {value}", "soglia {value}"),
        .readoutMass: ("mass {value}", "massa {value}"),
        .readoutCloseTo: ("close to “{label}” ({p})", "vicino a “{label}” ({p})"),
        .auditTitle: ("Decision history", "Storico delle decisioni"),
        .auditSearch: ("Search by app, outcome, reason…", "Cerca per app, esito, motivo…"),
        .auditSelect: ("Select a decision", "Seleziona una decisione"),
        .auditRawEvent: ("Raw event", "Evento grezzo"),
        .auditOpen: ("Full history…", "Storico completo…"),

        .askModeDo: ("Do", "Fai"),
        .askPlaceholderDo: ("Tell Leonard what to do…", "Di' a Leonard cosa fare…"),
        .taskPlanning: ("Planning…", "Pianifico…"),
        .taskLooking: ("Looking at {app}…", "Guardo {app}…"),
        .taskPressing: ("Pressing “{target}”", "Premo “{target}”"),
        .taskTyping: ("Typing into “{target}”", "Scrivo in “{target}”"),
        .taskScrolling: ("Scrolling “{target}”", "Scorro “{target}”"),
        .taskOpening: ("Opening {target}", "Apro {target}"),
        .taskWaiting: ("Waiting for the app…", "Aspetto l'app…"),
        .taskStop: ("Stop", "Ferma"),
        .taskUndo: ("Undo last step", "Annulla l'ultimo passo"),
        .taskDone: ("Done.", "Fatto."),
        .taskStopped: ("Stopped.", "Fermato."),
        .taskBlocked: ("Leonard couldn't go on: {reason}.", "Leonard non è riuscito ad andare avanti: {reason}."),
        .taskFailed: ("Something went wrong: {reason}.", "Qualcosa è andato storto: {reason}."),
        .taskAskPress: ("Press “{target}” in {app}?", "Premere “{target}” in {app}?"),
        .taskAskType: ("Type into “{target}” in {app}?", "Scrivere in “{target}” in {app}?"),
        .taskAskTypeSubmit: ("Type into “{target}” in {app} and press Return?", "Scrivere in “{target}” in {app} e premere Invio?"),
        .taskAskScroll: ("Scroll “{target}” in {app}?", "Scorrere “{target}” in {app}?"),
        .taskAskOpen: ("Open {target}?", "Aprire {target}?"),
        .taskAllow: ("Allow", "Consenti"),
        .taskAllowAlways: ("Always in {app}", "Sempre in {app}"),
        .taskPlanTitle: ("Plan", "Piano"),
        .taskStepsTitle: ("Steps", "Passi"),
        .taskEscHint: ("⎋ stops Leonard at any moment", "⎋ ferma Leonard in qualsiasi momento"),
        .taskNotTrusted: ("Leonard needs the Accessibility permission to use your apps.", "Leonard ha bisogno del permesso Accessibilità per usare le tue app."),
        .taskDisabled: ("Doing things in your apps is turned off in Settings.", "L'uso delle app è disattivato nelle Impostazioni."),
        .taskEngine: ("the engine didn't answer", "il motore non ha risposto"),
        .taskProtected: ("that app is protected, and Leonard never acts in it", "quell'app è protetta e Leonard non vi agisce mai"),
        .taskSecure: ("that's a password field", "è un campo password"),
        .taskTooManySteps: ("it took too many steps", "servivano troppi passi"),
        .taskKeptLoading: ("the app kept loading", "l'app continuava a caricare"),
        .taskAppDidNotRespond: ("the app didn't respond as expected", "l'app non ha risposto come previsto"),
        .taskNotSure: ("it wasn't sure what to do next", "non era sicuro di cosa fare dopo"),
        .taskNothingFits: ("nothing on screen fits the next step", "niente sullo schermo corrisponde al passo successivo"),
        .taskStuck: ("the same step wasn't changing anything", "lo stesso passo non cambiava nulla"),
        .reasonSends: ("This sends something.", "Questo invia qualcosa."),
        .reasonPays: ("This may spend money.", "Questo può spendere denaro."),
        .reasonDeletes: ("This deletes or overwrites something.", "Questo elimina o sovrascrive qualcosa."),
        .reasonPublishes: ("This publishes, shares or answers for you.", "Questo pubblica, condivide o risponde per te."),
        .reasonSigns: ("This affects your account or signs something.", "Questo tocca il tuo account o firma qualcosa."),
        .reasonRunsCommand: ("Text typed here can run as a command.", "Il testo scritto qui può essere eseguito come comando."),
        .reasonSendsMessage: ("Pressing Return sends this message.", "Premere Invio invia questo messaggio."),
        .reasonClosesWithoutSaving: ("Unsaved work may be lost.", "Il lavoro non salvato potrebbe andare perso."),
        .reasonEveryStep: ("You asked to approve every step.", "Hai chiesto di approvare ogni passo."),
        .settingsActing: ("Using your apps", "Uso delle app"),
        .settingsActingEnabled: ("Let Leonard use your apps to do what you ask", "Lascia che Leonard usi le tue app per fare ciò che chiedi"),
        .settingsActingHint: ("Leonard presses, types and scrolls like you would, in the app in front. ⎋ stops it at any moment.", "Leonard preme, scrive e scorre come faresti tu, nell'app in primo piano. ⎋ lo ferma in qualsiasi momento."),
        .settingsActingApproval: ("Ask me before", "Chiedimi prima di"),
        .settingsApprovalImportant: ("Sending, paying or deleting", "Inviare, pagare o eliminare"),
        .settingsApprovalEvery: ("Every step", "Ogni passo"),
        .settingsAllowRules: ("Always allowed", "Sempre consentiti"),
        .settingsAllowRulesEmpty: ("Nothing yet. Choose “Always” when Leonard asks.", "Ancora niente. Scegli “Sempre” quando Leonard chiede."),
        .mindTasks: ("What Leonard did", "Cosa ha fatto Leonard"),
        .mindTasksEmpty: ("No tasks yet. Press ⌥Space and tell Leonard what to do.", "Ancora nessun compito. Premi ⌥Spazio e di' a Leonard cosa fare."),
        .mindTaskSteps: ("{count} steps", "{count} passi"),

        .mindSpecialist: ("Your specialist", "Il tuo specialista"),
        .mindSpecialistLearning: ("Learning from your answers. It starts deciding alone after {count} more.", "Sta imparando dalle tue risposte. Inizierà a decidere da solo dopo altre {count}."),
        .mindSpecialistChecking: ("Learning from your answers; not yet sure enough to decide alone ({reason}).", "Sta imparando dalle tue risposte; non è ancora abbastanza sicuro per decidere da solo ({reason})."),
        .mindSpecialistActive: ("Trained on this Mac from {count} of your answers.", "Addestrato su questo Mac da {count} tue risposte."),
        .mindSpecialistAgreement: ("Agrees with you {specialist} of the time (the general model: {general}).", "È d'accordo con te il {specialist} delle volte (il modello generale: {general})."),
        .mindSpecialistAlone: ("Decided alone {count} times in {ms}, instead of {general}.", "Ha deciso da solo {count} volte in {ms}, invece di {general}."),
        .mindSpecialistBadge: ("Your specialist", "Il tuo specialista"),

        .settingsChatProactive: ("Conversations in chat apps", "Conversazioni nelle app di chat"),
        .settingsChatProactiveHint: ("Slack, WhatsApp, Messages, Teams, Telegram and others: when someone asks you something, Leonard offers a reply and puts it in the message box. It never sends.", "Slack, WhatsApp, Messaggi, Teams, Telegram e altre: quando qualcuno ti chiede qualcosa, Leonard propone una risposta e la mette nella casella del messaggio. Non invia mai."),

        .promiseDone: ("Done", "Fatto"),
        .promiseTomorrow: ("Remind me tomorrow", "Ricordamelo domani"),
        .promiseNotAPromise: ("Not a promise", "Non è una promessa"),
        .promiseTo: ("Promised to {person}", "Promesso a {person}"),
        .promiseToDue: ("Promised to {person} · {when}", "Promesso a {person} · {when}"),
        .promiseOverdue: ("overdue", "in ritardo"),
        .promiseToday: ("due today", "scade oggi"),
        .promiseTomorrowDue: ("due tomorrow", "scade domani"),
        .settingsCalendar: ("Calendar — for meeting briefs", "Calendario — per prepararti agli incontri"),
        .settingsCalendarAllow: ("Allow calendar access…", "Consenti l'accesso al calendario…"),
        .settingsMeetingPrep: ("Brief me before meetings", "Preparami prima degli incontri"),
        .settingsMeetingPrepHint: ("Ten minutes before a meeting with other people, Leonard offers what you know about it: what you saw, what you promised them. Reads your calendar on this Mac; never changes it.", "Dieci minuti prima di un incontro con altre persone, Leonard ti propone ciò che sai: cosa hai visto, cosa hai promesso. Legge il calendario su questo Mac; non lo modifica mai."),
        .settingsTrackPromises: ("Keep track of what I promise", "Tieni traccia di ciò che prometto"),
        .settingsTrackPromisesHint: ("Leonard reads the mail you send (Mail's Sent mailbox, on this Mac) and keeps the promises in it — “I'll send it by Friday” — until you mark them done.", "Leonard legge la posta che invii (la cartella Inviati di Mail, su questo Mac) e tiene le promesse che contiene — “te lo mando venerdì” — finché non le segni come fatte."),

        .voiceListening: ("Listening…", "Ti ascolto…"),
        .voiceTalk: ("Talk", "Parla"),
        .voiceNotAllowed: ("Speech recognition is not allowed for Leonard. You can allow it in System Settings › Privacy & Security.", "Il riconoscimento vocale non è consentito a Leonard. Puoi consentirlo in Impostazioni di Sistema › Privacy e sicurezza."),
        .voiceNoMicrophone: ("Leonard can't use the microphone. You can allow it in System Settings › Privacy & Security › Microphone.", "Leonard non può usare il microfono. Puoi consentirlo in Impostazioni di Sistema › Privacy e sicurezza › Microfono."),
        .voiceUnavailable: ("Speech recognition isn't available right now.", "Il riconoscimento vocale non è disponibile in questo momento."),
        .voiceNotOnDevice: ("On-device dictation for this language isn't installed, and Leonard never sends your voice anywhere. Turn on Dictation in System Settings › Keyboard to download it.", "La dettatura sul dispositivo per questa lingua non è installata, e Leonard non invia mai la tua voce altrove. Attiva la Dettatura in Impostazioni di Sistema › Tastiera per scaricarla."),
        .settingsTalkHotkey: ("Talk to Leonard", "Parla con Leonard"),

        .settingsReadImages: ("Also read text in images", "Leggi anche il testo nelle immagini"),
        .settingsReadImagesHint: ("For windows that show text as pixels — a scanned PDF, a remote desktop — Leonard can recognize the words on this Mac. Only the text is kept, never the image. Needs the Screen Recording permission.", "Per le finestre che mostrano il testo come immagine — un PDF scansionato, un desktop remoto — Leonard può riconoscere le parole su questo Mac. Conserva solo il testo, mai l'immagine. Richiede il permesso Registrazione schermo."),

        .taskShowMe: ("Show me how", "Mostrami come"),
        .taskWatching: ("Do it yourself: Leonard is watching and will remember how. Press Done when you've finished.", "Fallo tu: Leonard guarda e si ricorderà come si fa. Premi Fatto quando hai finito."),
        .taskWatchDone: ("Done", "Fatto"),
        .taskLearned: ("Learned. Next time Leonard will do it this way.", "Imparato. La prossima volta Leonard farà così."),

        .genericCancel: ("Cancel", "Annulla"),
        .genericDelete: ("Delete", "Elimina"),
        .genericOK: ("OK", "OK"),
        .genericClose: ("Close", "Chiudi"),
        .genericError: ("Error", "Errore"),
        .relToday: ("today", "oggi"),
        .relYesterday: ("yesterday", "ieri"),
        .relDaysAgo: ("{count} days ago", "{count} giorni fa"),
        .relMinutesAgo: ("{count} min ago", "{count} min fa"),
        .relJustNow: ("just now", "adesso"),
        .relHoursAgo: ("{count} h ago", "{count} h fa"),
    ]
    // swiftlint:enable line_length

    /// "just now", "5 min ago", "3 h ago", "yesterday", "4 days ago".
    public static func relative(_ ts: Double, now: Double = Date().timeIntervalSince1970) -> String {
        let seconds = max(0, now - ts)
        if seconds < 60 { return t(.relJustNow) }
        if seconds < 3600 { return t(.relMinutesAgo, ["count": "\(Int(seconds / 60))"]) }
        if seconds < 86400 { return t(.relHoursAgo, ["count": "\(Int(seconds / 3600))"]) }
        let days = Int(seconds / 86400)
        return days == 1 ? t(.relYesterday) : t(.relDaysAgo, ["count": "\(days)"])
    }
}
