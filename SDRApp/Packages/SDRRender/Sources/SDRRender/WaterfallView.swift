import SwiftUI
import MetalKit

/// SwiftUI wrapper for the Metal waterfall + spectrum view.
public struct WaterfallView: UIViewRepresentable {
    let renderer: WaterfallRenderer
    let isActive: Bool

    public final class Coordinator {
        var wasActive = true
    }

    public init(renderer: WaterfallRenderer, isActive: Bool = true) {
        self.renderer = renderer
        self.isActive = isActive
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeUIView(context: Context) -> MTKView {
        let device = renderer.device
        let view = MTKView(frame: .zero, device: device)
        view.delegate = renderer
        view.preferredFramesPerSecond = renderer.targetFPS
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.enableSetNeedsDisplay = !isActive
        view.isPaused = !isActive
        view.isOpaque = true
        context.coordinator.wasActive = isActive

        return view
    }

    public func updateUIView(_ uiView: MTKView, context: Context) {
        uiView.preferredFramesPerSecond = renderer.targetFPS
        uiView.enableSetNeedsDisplay = !isActive
        uiView.isPaused = !isActive
        if isActive {
            // no-op
        } else if context.coordinator.wasActive {
            uiView.setNeedsDisplay()
        }
        context.coordinator.wasActive = isActive
    }
}
