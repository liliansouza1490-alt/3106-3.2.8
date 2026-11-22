import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var appState: AppState
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue

    var body: some View {
        NavigationStack {
            Form {
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

                Section {
                    HStack {
                        Text(language.text("settings.current_version"))
                        Spacer()
                        Text(language.text(appState.isSupported ? "settings.supported" : "settings.unsupported"))
                            .foregroundStyle(appState.isSupported ? Color.green : Color.red)
                    }
                    LabeledContent("iOS 17", value: ExploitSupportPolicy.verifiedIOS17Range)
                    LabeledContent("iOS 18", value: ExploitSupportPolicy.verifiedIOS18Range)
                    LabeledContent(
                        "iOS 26",
                        value: "\(ExploitSupportPolicy.verifiedIOS26BadQueryRange) · \(ExploitSupportPolicy.verifiedIOS26WorseQueryRange)"
                    )
                    LabeledContent("iOS 27", value: ExploitSupportPolicy.verifiedIOS27Range)
                    LabeledContent(
                        "iOS 27.3",
                        value: "\(ExploitSupportPolicy.verifiedIOS27BuildGatedRange) · \(ExploitSupportPolicy.verifiedIOS27Builds.joined(separator: ", "))"
                    )
                    if let reason = appState.unsupportedMessage {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text(language.text("settings.verified_versions"))
                } footer: {
                    Text(language.text("settings.supported_versions_footer"))
                }
            }
            .tint(AppTheme.accent)
            .scrollContentBackground(.hidden)
            .background(AppTheme.pageBackground.ignoresSafeArea())
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
}

private struct LanguageOptionRow: View {
    let language: AppLanguage
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text(language.rawValue.uppercased())
                .font(.caption.weight(.bold).monospaced())
                .foregroundStyle(AppTheme.accent)
                .frame(width: 48, height: 36)
                .background(AppTheme.accent.opacity(0.12), in: Capsule())

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
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 18)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
