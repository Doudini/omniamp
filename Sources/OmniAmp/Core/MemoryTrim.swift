import Darwin
import Foundation

/// Hands freed malloc pages back to the system after bursts of temporary work (launch, tag loading,
/// switching looks). Without it, memory freed after a peak still counts towards the app's footprint.
enum MemoryTrim {
    @MainActor private static var pending: DispatchWorkItem?

    /// Trim once things have settled (debounced; call from the main thread).
    @MainActor static func soon(after delay: TimeInterval = 2) {
        pending?.cancel()
        let work = DispatchWorkItem { malloc_zone_pressure_relief(nil, 0) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

import AppKit

extension NSView {
    /// AppKit draws large views "asynchronously": Core Animation replays the drawing on the GPU inside our
    /// process, which loads Metal, its shader archives and command buffers (~10–15 MB) for a few views that
    /// hardly ever redraw. Call from viewWillDraw() to keep such a view on plain CPU drawing.
    func keepDrawingOnCPU() {
        guard let layer else { return }
        layer.drawsAsynchronously = false
        layer.sublayers?.forEach { $0.drawsAsynchronously = false }
    }
}
