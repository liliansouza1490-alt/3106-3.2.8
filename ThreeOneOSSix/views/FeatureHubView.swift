import SwiftUI

/// Compatibility wrapper; the app now opens Patch Projects directly.
struct FeatureHubView: View {
    let onOpenSettings: () -> Void

    init(onOpenSettings: @escaping () -> Void = {}) {
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        PatchProjectsView(onOpenSettings: onOpenSettings)
    }
}
