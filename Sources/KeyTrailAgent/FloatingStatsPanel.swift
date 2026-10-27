import Foundation
import KeyTrailIPC
import KeyTrailRuntime
import KeyTrailFloatingUI

/// Shared lightweight AppKit view; queries are serialized by the collector IPC.
@MainActor
final class ResidentFloatingStatsPanel {
    private let panel: KeyTrailFloatingUI.FloatingStatsPanel
    init(runtime: RuntimeController, didClose: @escaping () -> Void,
         openDashboard: @escaping () -> Void) {
        panel = KeyTrailFloatingUI.FloatingStatsPanel(
            client: RuntimeClient(socketURL: runtime.directory.appendingPathComponent("engine.sock")),
            isDemo: runtime.isDemo,
            preferencesNamespace: "resident." + runtime.directory.lastPathComponent,
            onClose: didClose, onOpenDashboard: openDashboard)
    }
    func show() { panel.show() }
    func close() { panel.close() }
}
