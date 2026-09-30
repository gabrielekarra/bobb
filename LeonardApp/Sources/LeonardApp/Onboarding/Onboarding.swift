import AppKit
import Observation
import SwiftUI
import LeonardCore

@MainActor
@Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable {
        case welcome, privacy, permissions, model, ready
    }

    var step: Step = .welcome

    func next() {
        step = Step(rawValue: step.rawValue + 1) ?? .ready
    }

    func back() {
        step = Step(rawValue: step.rawValue - 1) ?? .welcome
    }
}

/// Five screens, each answering one question a careful person asks before
/// letting an assistant read their screen: what is this, where does my data
/// go, what exactly can it see, what does it download, and what now.
struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    @Bindable var permissions: Permissions
    @Bindable var downloader: ModelDownloader
    var calendar: CalendarSensor?
    let hotkey: Hotkey
    let startDownload: () -> Void
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case .welcome: welcome
                case .privacy: privacy
                case .permissions: permissionsStep
                case .model: modelStep
                case .ready: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 44)
            .padding(.top, 40)

            footer
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
                .background(Color.primary.opacity(0.03))
        }
        .frame(width: 640, height: 520)
        .bobbWindowStyle()
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            LeonardAppIcon(size: 64)
            Text(L10n.t(.onbWelcomeTitle))
                .font(.system(size: 30, weight: .bold))
            Text(L10n.t(.onbWelcomeBody))
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                feature("envelope.badge", L10n.t(.onbFeatureMessages))
                feature("cursorarrow.rays", L10n.t(.onbFeatureDo))
                feature("brain.head.profile", L10n.t(.onbFeatureMemory))
                feature("mic", L10n.t(.onbFeatureVoice, ["hotkey": hotkey.display, "talk": Hotkey.talk.display]))
            }
            .padding(.top, 8)
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundStyle(Theme.accent)
            Text(L10n.t(.onbPrivacyTitle))
                .font(.system(size: 26, weight: .bold))
            VStack(alignment: .leading, spacing: 14) {
                feature("desktopcomputer", L10n.t(.onbPrivacy1))
                feature("network.slash", L10n.t(.onbPrivacy2))
                feature("text.viewfinder", L10n.t(.onbPrivacy3))
                feature("trash", L10n.t(.onbPrivacy4))
            }
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t(.onbPermissionsTitle))
                .font(.system(size: 26, weight: .bold))
            Text(L10n.t(.onbPermissionsBody))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            permissionRow(
                icon: "accessibility", title: L10n.t(.settingsAccessibility), why: L10n.t(.onbAccessibilityWhy),
                status: permissions.accessibility, request: { permissions.requestAccessibility() }
            )
            permissionRow(
                icon: "envelope", title: L10n.t(.settingsAutomation), why: L10n.t(.onbAutomationWhy),
                status: permissions.mailAutomation, request: { permissions.requestMailAutomation() }
            )
            if let calendar {
                permissionRow(
                    icon: "calendar", title: L10n.t(.settingsCalendar), why: L10n.t(.onbCalendarWhy),
                    status: calendar.access == .granted ? .granted : (calendar.access == .denied ? .denied : .notDetermined),
                    request: { calendar.access == .denied ? Permissions.openCalendarSettings() : calendar.requestAccess() }
                )
            }
        }
        .onAppear { permissions.refresh() }
    }

    private func permissionRow(icon: String, title: String, why: String, status: Permissions.Status, request: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(why)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if status == .granted {
                Label(L10n.t(.onbGranted), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 12, weight: .medium))
            } else {
                Button(L10n.t(.onbGrant), action: request)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "cpu")
                .font(.system(size: 34))
                .foregroundStyle(Theme.accent)
            Text(L10n.t(.onbModelTitle))
                .font(.system(size: 26, weight: .bold))
            Text(L10n.t(.onbModelBody))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            downloadState
            Text(L10n.t(.onbModelOffline, ["path": downloader.modelsDirectory.path]))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            Text("\(downloader.manifest.id) · \(downloader.manifest.license)")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var downloadState: some View {
        switch downloader.phase {
        case .idle:
            Button(L10n.t(.onbDownload), action: startDownload)
                .buttonStyle(PrimaryButtonStyle())
        case .downloading(let fraction, let received, let total):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction)
                Text(L10n.t(.onbDownloading, ["progress": "\(ModelInstallation.formatBytes(received)) / \(ModelInstallation.formatBytes(total))"]))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .verifying(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction)
                Text(L10n.t(.onbVerifying)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .installed:
            Label(L10n.t(.onbModelReady), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 13, weight: .medium))
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.t(.onbModelFailed, ["detail": message]), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.attention)
                    .font(.system(size: 12))
                Button(L10n.t(.onbRetry), action: startDownload)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 38))
                .foregroundStyle(.green)
            Text(L10n.t(.onbReadyTitle))
                .font(.system(size: 28, weight: .bold))
            Text(L10n.t(.onbReadyBody))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                feature("keyboard", L10n.t(.onbTryIt, ["hotkey": hotkey.display]))
                feature("cursorarrow.rays", L10n.t(.onbTryDo))
                feature("mic", L10n.t(.onbTryVoice, ["talk": Hotkey.talk.display]))
            }
            .padding(12)
            .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { step in
                    Circle()
                        .fill(step == model.step ? Theme.accent : Color.primary.opacity(0.15))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            if model.step != .welcome && model.step != .ready {
                Button(L10n.t(.onbBack)) { model.back() }
                    .buttonStyle(QuietButtonStyle())
            }
            if model.step == .model && downloader.phase != .installed {
                Button(L10n.t(.onbSkip)) { model.next() }
                    .buttonStyle(QuietButtonStyle())
            }
            if model.step == .ready {
                Button(L10n.t(.onbDone), action: finish)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(L10n.t(.onbContinue)) { model.next() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.step == .model && downloader.phase != .installed && !isBusyOrFailed)
            }
        }
    }

    private var isBusyOrFailed: Bool {
        switch downloader.phase {
        case .failed: return true
        default: return false
        }
    }
}
