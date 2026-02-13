import SwiftUI
import MetalKit

/// SwiftUI wrapper for the Metal waterfall + spectrum view.
public struct WaterfallView: UIViewRepresentable {
    let renderer: WaterfallRenderer

    public init(renderer: WaterfallRenderer) {
        self.renderer = renderer
    }

    public func makeUIView(context: Context) -> MTKView {
        let device = renderer.device
        let view = MTKView(frame: .zero, device: device)
        view.delegate = renderer
        view.preferredFramesPerSecond = renderer.targetFPS
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.enableSetNeedsDisplay = false
        view.isPaused = false

        return view
    }

    public func updateUIView(_ uiView: MTKView, context: Context) {
        uiView.preferredFramesPerSecond = renderer.targetFPS
    }
}

/// SwiftUI spectrum-only view using Canvas (simpler, for when Metal waterfall is not needed).
public struct SpectrumCanvasView: View {
    let bins: [Float]
    let peakBins: [Float]
    var lineColor: Color = .green
    var peakColor: Color = .yellow
    var showPeaks: Bool = false

    public init(bins: [Float], peakBins: [Float] = [], lineColor: Color = .green, showPeaks: Bool = false) {
        self.bins = bins
        self.peakBins = peakBins
        self.lineColor = lineColor
        self.showPeaks = showPeaks
    }

    public var body: some View {
        Canvas { context, size in
            guard !bins.isEmpty else { return }

            let w = size.width
            let h = size.height
            let count = bins.count
            let step = w / CGFloat(count - 1)

            // Draw spectrum line
            var path = Path()
            for i in 0..<count {
                let x = CGFloat(i) * step
                let y = h * (1.0 - CGFloat(bins[i]))
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(path, with: .color(lineColor), lineWidth: 1.5)

            // Draw peak hold
            if showPeaks && !peakBins.isEmpty {
                var peakPath = Path()
                for i in 0..<min(peakBins.count, count) {
                    let x = CGFloat(i) * step
                    let y = h * (1.0 - CGFloat(peakBins[i]))
                    if i == 0 {
                        peakPath.move(to: CGPoint(x: x, y: y))
                    } else {
                        peakPath.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                context.stroke(peakPath, with: .color(peakColor), lineWidth: 0.75)
            }
        }
    }
}
