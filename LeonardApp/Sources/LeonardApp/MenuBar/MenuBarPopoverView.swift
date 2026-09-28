import SwiftUI
import LeonardCore

/// The front door. A click on the menu bar icon shows, in order: whether
/// Leonard is working, anything that needs finishing (setup, license),
/// a field to ask something, what is waiting for the user, how much
/// Leonard stayed quiet, and the way to everything else.
struct MenuBarPopoverView: View {
    @Bindable var state: AppState
    let actions: MenuBarActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let notice = notice {
                notice
                Divider()
            }
            askField
                .padding(.horizontal, 12)
                .padding(.top, 10)
            forYou
            Divider()
            footer
        }
        .frame(width: 340)
        .tint(Theme.accent)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            LeonardMark(size: 24, color: markColor, eyes: markEyes)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(statusSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { state.watching }, set: { actions.setWatching($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(state.watching ? L10n.t(.menuPause) : L10n.t(.menuResume))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var statusTitle: String {
        switch state.activityState {
        case .disconnected: L10n.t(.statusDisconnected)
        case .starting: L10n.t(.statusStarting)
        case .setupNeeded: L10n.t(.statusModelMissing)
        case .paused: state.entitlement.allowsAssistance ? L10n.t(.statusPaused) : L10n.t(.statusTrialExpired)
        case .watching, .waitingForYou: L10n.t(.statusWatching)
        case .thinking: L10n.t(.statusThinking)
        case .suggesting: L10n.t(.statusSuggesting)
        }
    }

    private var statusSubtitle: String {
        if let summary = state.stats?.decisions, summary.decisions > 0 {
            return L10n.t(.menuSilentToday, ["count": "\(summary.silent)"]) + " · " + L10n.t(.menuHelpedToday, ["count": "\(summary.suggested)"])
        }
        switch state.connection {
        case .ready(let ready): return ready.model.components(separatedBy: "/").last ?? ready.model
        default: return state.daemonStatus?.detail.components(separatedBy: "/").last ?? ""
        }
    }

    private var markColor: Color {
        switch state.activityState {
        case .disconnected, .paused: .secondary
        case .starting, .setupNeeded, .suggesting, .waitingForYou: Theme.attention
        case .watching, .thinking: .primary
        }
    }

    private var markEyes: Glasses.Eyes {
        switch state.activityState {
        case .paused: .closed
        case .disconnected: .none
        case .suggesting, .waitingForYou: .look(CGVector(dx: -0.4, dy: 0.9))
        default: .up
        }
    }

    // MARK: Notices

    private var notice: AnyView? {
        if state.activityState == .setupNeeded || !state.settings.onboardingCompleted {
            return AnyView(noticeCard(
                icon: "sparkles", text: L10n.t(.statusModelMissing), button: L10n.t(.menuOpenSetup), action: actions.openOnboarding
            ))
        }
        switch state.entitlement {
        case .trialExpired:
            return AnyView(noticeCard(icon: "hourglass", text: L10n.t(.licenseTrialExpired), button: L10n.t(.licenseBuy), action: actions.openLicense))
        case .updatesExpired(let license):
            return AnyView(noticeCard(
                icon: "arrow.triangle.2.circlepath",
                text: L10n.t(.licenseUpdatesExpired, ["date": LicenseDates.display(license.updatesUntil)]),
                button: L10n.t(.licenseEnter), action: actions.openLicense
            ))
        case .trial(let days) where days <= 3:
            return AnyView(noticeCard(icon: "hourglass", text: L10n.t(.licenseTrial, ["days": "\(days)"]), button: L10n.t(.licenseBuy), action: actions.openLicense))
        default:
            return nil
        }
    }

    private func noticeCard(icon: String, text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Theme.attention)
            Text(text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(button, action: action)
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(12)
        .background(Theme.attention.opacity(0.07))
    }

    // MARK: Ask

    private var askField: some View {
        Button(action: actions.openCommandBar) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass")
                    .foregroundStyle(Theme.accent)
                Text(L10n.t(.menuAskPlaceholder))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(state.settings.hotkey.display)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: For you

    private var forYou: some View {
        VStack(alignment: .leading, spacing: 8) {
            Theme.sectionTitle(L10n.t(.menuForYou))
            if state.forYou.isEmpty {
                Text(L10n.t(.menuNothingForYou))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(state.forYou.prefix(5), id: \.id) { decision in
                    forYouRow(decision)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func forYouRow(_ decision: DecisionFrame) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(decision.action == .suggest ? Theme.attention : Theme.accent.opacity(0.6))
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(decision.suggestion?.title ?? "")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                Text(decision.suggestion?.detail ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(L10n.relative(decision.ts))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Button(decision.suggestion?.cta ?? L10n.t(.overlayPrepare)) { actions.approve(decision) }
                    .buttonStyle(PrimaryButtonStyle())
                Button(L10n.t(.overlayIgnore)) { actions.dismiss(decision) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 2) {
            footerButton(L10n.t(.menuMind), "brain", action: actions.openMind)
            footerButton(L10n.t(.menuMemory), "tray.full", action: actions.openMemory)
            footerButton(L10n.t(.menuSettings), "gearshape", action: actions.openSettings)
            Spacer()
            Button(action: actions.quit) {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L10n.t(.menuQuit))
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private func footerButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

/// Everything the popover can ask the app to do, as closures, so the view
/// stays a pure function of `AppState`.
struct MenuBarActions {
    var approve: (DecisionFrame) -> Void
    var dismiss: (DecisionFrame) -> Void
    var setWatching: (Bool) -> Void
    var openCommandBar: () -> Void
    var openMind: () -> Void
    var openMemory: () -> Void
    var openSettings: () -> Void
    var openLicense: () -> Void
    var openOnboarding: () -> Void
    var quit: () -> Void
}
