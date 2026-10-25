import SwiftUI

/// News about DockFolder updates at the bottom of the sidebar: a newer version to install, how
/// installing it is going, or what went wrong. Nothing when there's no news.
struct UpdateCard: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Group {
            switch updater.state {
            case .idle:
                EmptyView()
            case .checking:
                card { progress("Checking for updates…") }
            case .available(let release):
                card { available(release) }
            case .installing(_, let step):
                card { progress(step, detail: "DockFolder starts again when it’s done.") }
            case .needsRestart(let version):
                card {
                    note("DockFolder \(version) is installed", detail: "Open DockFolder again to start using it.",
                         symbol: "checkmark.circle.fill", color: .green)
                    Button("Quit DockFolder") { NSApp.terminate(nil) }
                        .controlSize(.small)
                        .glassButtonStyle(prominent: true)
                }
            case .updatingFolders(let version):
                card { progress("Updating your folders…", detail: "To DockFolder \(version).") }
            case .updated(let version):
                card {
                    note("Updated to DockFolder \(version)", detail: "Your folders are up to date too.",
                         symbol: "checkmark.circle.fill", color: .green, closes: true)
                }
            case .failed(let release, let message):
                card { failure(release, message) }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: updater.state)
    }

    private func available(_ release: Release) -> some View {
        let installsHere = updater.canInstall && release.archive != nil
        return VStack(alignment: .leading, spacing: 10) {
            note("DockFolder \(release.version) is available",
                 detail: updater.currentVersion.map { "You have \($0)." },
                 symbol: "arrow.down.circle.fill", color: .accentColor, closes: true)
            HStack(spacing: 10) {
                Button(installsHere ? "Install Update" : "Download") {
                    Task { await updater.install(release) }
                }
                .controlSize(.small)
                .glassButtonStyle(prominent: true)
                Button("What’s New") { updater.openPage(of: release) }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
            if !updater.canInstall {
                Text("Move DockFolder to Applications to install updates from here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func failure(_ release: Release?, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            note("Couldn’t update DockFolder", detail: message,
                 symbol: "exclamationmark.triangle.fill", color: .orange, closes: true)
            if let release {
                HStack(spacing: 10) {
                    Button("Try Again") { Task { await updater.install(release) } }
                        .controlSize(.small)
                        .glassButtonStyle()
                    Button("Download") { updater.openPage(of: release) }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
        }
    }

    private func note(_ title: String, detail: String?, symbol: String, color: Color, closes: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if closes {
                Button { updater.dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(CircleIconButtonStyle(diameter: 18))
                .help("Hide")
            }
        }
    }

    private func progress(_ title: String, detail: String? = nil) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassBackground(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
