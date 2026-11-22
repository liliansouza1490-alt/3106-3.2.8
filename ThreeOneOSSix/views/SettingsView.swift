import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var appState: AppState
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue

    var body: some View {
        NavigationStack {
            settingsForm
                .tint(AppTheme.accent)
                .scrollContentBackground(.hidden)
                .background(AppTheme.pageBackground.ignoresSafeArea())
                .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .navigationTitle(language.text("settings.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(language.text("common.done")) { dismiss() }
                            .fontWeight(.semibold)
                    }
                }
        }
    }

    private var settingsForm: some View {
        Form {
            languageSection
            verifiedVersionsSection
        }
    }

    private var languageSection: some View {
        Section(language.text("settings.language")) {
            ForEach(AppLanguage.allCases) { option in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        languageCode = option.rawValue
                    }
                } label: {
                    LanguageOptionRow(
                        language: option,
                        isSelected: languageCode == option.rawValue
                    )
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 7, leading: 4, bottom: 7, trailing: 4))
                .listRowBackground(Color.clear)
            }
        }
    }

    private var verifiedVersionsSection: some View {
        Section {
            versionStatusRow
            versionRow("iOS 17", value: ExploitSupportPolicy.verifiedIOS17Range)
            versionRow("iOS 18", value: ExploitSupportPolicy.verifiedIOS18Range)
            versionRow(
                "iOS 26",
                value: "\(ExploitSupportPolicy.verifiedIOS26BadQueryRange) · \(ExploitSupportPolicy.verifiedIOS26WorseQueryRange)"
            )
            versionRow("iOS 27", value: ExploitSupportPolicy.verifiedIOS27Range)
            versionRow(
                "iOS 27.3",
                value: "\(ExploitSupportPolicy.verifiedIOS27BuildGatedRange) · \(ExploitSupportPolicy.verifiedIOS27Builds.joined(separator: ", "))"
            )
            if let reason = appState.unsupportedMessage {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(.ultraThinMaterial)
            }
        } header: {
            Text(language.text("settings.verified_versions"))
        } footer: {
            Text(language.text("settings.supported_versions_footer"))
        }
    }

    private var versionStatusRow: some View {
        HStack {
            Text(language.text("settings.current_version"))
            Spacer()
            Text(language.text(appState.isSupported ? "settings.supported" : "settings.unsupported"))
                .foregroundStyle(appState.isSupported ? Color.green : Color.red)
        }
        .listRowBackground(.ultraThinMaterial)
    }

    private func versionRow(_ title: String, value: String) -> some View {
        LabeledContent(title, value: value)
            .listRowBackground(.ultraThinMaterial)
    }
}

private struct LanguageOptionRow: View {
    let language: AppLanguage
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text(language.flag)
                .font(.system(size: 30))
                .frame(width: 48, height: 48)
                .background(.thinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(
                            isSelected ? AppTheme.accent.opacity(0.65) : Color.white.opacity(0.22),
                            lineWidth: isSelected ? 1.5 : 0.7
                        )
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(language.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(language.locale.identifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? AppTheme.accent : Color.secondary.opacity(0.45))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassCard(cornerRadius: 20)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
