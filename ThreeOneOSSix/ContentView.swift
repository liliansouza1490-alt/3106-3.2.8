import SwiftUI

struct ContentView: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var patchStore: PatchProjectStore
    @EnvironmentObject private var repositoryStore: PackageRepositoryStore
    @EnvironmentObject private var appState: AppState
    @State private var showSettings = false
    @State private var showAppGroupAlert = false

    var body: some View {
        PatchProjectsView(onOpenSettings: openSettings)
            .tint(AppTheme.accent)
            .imageScale(.small)
            .onAppear {
#if !targetEnvironment(simulator)
                if SandboxAccess.needsWorseQuery, SandboxAccess.appGroup == nil {
                    showAppGroupAlert = true
                }
#endif
            }
            .alert(language.text("appgroup.title"), isPresented: $showAppGroupAlert) {
                Button(language.text("common.ok")) {}
            } message: {
                Text(language.text("appgroup.message"))
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .overlay(alignment: .top) {
                if appState.needsUnlock {
                    NavigationLink {
                        UnlockView()
                    } label: {
                        UnlockBanner()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                }
            }
            .patchStorePresentation(patchStore)
            .repositoryStorePresentation(repositoryStore, patchStore: patchStore)
    }

    private func openSettings() {
        showSettings = true
    }
}
