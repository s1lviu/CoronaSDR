import Foundation
import Metal
import MetalKit
import SDRSupport

/// Metal-based waterfall renderer.
/// Each FFT frame becomes one row in a scrolling texture.
/// Scrolling is done via texture coordinate offset (no CPU-side image shifts).
public final class WaterfallRenderer: NSObject, MTKViewDelegate {
    private enum ColorScheme: UInt32 {
        case classic = 0
        case thermal = 1
        case grayscale = 2
    }

    private struct WaterfallUniforms {
        var scrollOffset: Float
        var colorScheme: UInt32
    }

    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var waterfallPipeline: MTLRenderPipelineState?
    private var spectrumPipeline: MTLRenderPipelineState?

    // Waterfall texture
    private var waterfallTexture: MTLTexture?
    private var textureWidth: Int = 2048
    private var textureHeight: Int = 512
    private var currentRow: Int = 0
    private var scrollOffset: Float = 0

    // Spectrum bins for overlay
    private let spectrumLock = NSLock()
    private var spectrumBuffer: MTLBuffer?
    private var spectrumBufferCapacity: Int = 0
    private var spectrumSampleCount: Int = 0
    // Spectrum is rendered in a dedicated top view; keep waterfall clean.
    private var showSpectrum: Bool = false
    private var renderingActive: Bool = true
    private var colorScheme: ColorScheme = .classic

    // FPS tracking
    private var frameCount: Int = 0
    private var lastFPSTime: CFAbsoluteTime = 0
    public var currentFPS: Double = 0

    // Debug
    private var rowsWritten: Int = 0

    // Target FPS
    public var targetFPS: Int = 20

    public init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        super.init()
        buildPipelines()
        createWaterfallTexture()
    }

    /// Enable/disable active rendering (e.g. when radio tab is not visible).
    public func setRenderingActive(_ isActive: Bool) {
        renderingActive = isActive
    }

    private func buildPipelines() {
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle.module) else {
            SDRLogger.ui.error("Failed to load Metal shader library")
            SDRDebug.print("❌ Metal: Failed to load shader library from bundle")
            return
        }
        SDRDebug.print("✅ Metal: Shader library loaded")

        // Waterfall pipeline
        let waterfallDesc = MTLRenderPipelineDescriptor()
        waterfallDesc.vertexFunction = library.makeFunction(name: "waterfallVertexShader")
        waterfallDesc.fragmentFunction = library.makeFunction(name: "waterfallFragmentShader")
        waterfallDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            waterfallPipeline = try device.makeRenderPipelineState(descriptor: waterfallDesc)
            SDRDebug.print("✅ Metal: Waterfall pipeline created")
        } catch {
            SDRLogger.ui.error("Failed to create waterfall pipeline: \(error)")
            SDRDebug.print("❌ Metal: Waterfall pipeline failed: \(error)")
        }

        // Spectrum pipeline
        let spectrumDesc = MTLRenderPipelineDescriptor()
        spectrumDesc.vertexFunction = library.makeFunction(name: "spectrumVertexShader")
        spectrumDesc.fragmentFunction = library.makeFunction(name: "spectrumFragmentShader")
        spectrumDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        spectrumDesc.colorAttachments[0].isBlendingEnabled = true
        spectrumDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        spectrumDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha

        do {
            spectrumPipeline = try device.makeRenderPipelineState(descriptor: spectrumDesc)
            SDRDebug.print("✅ Metal: Spectrum pipeline created")
        } catch {
            SDRLogger.ui.error("Failed to create spectrum pipeline: \(error)")
            SDRDebug.print("❌ Metal: Spectrum pipeline failed: \(error)")
        }
    }

    private func createWaterfallTexture() {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: textureWidth,
            height: textureHeight,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        waterfallTexture = device.makeTexture(descriptor: desc)

        // Clear texture to 0 (black)
        if let texture = waterfallTexture {
            let zeros = [Float](repeating: 0, count: textureWidth)
            let bytesPerRow = textureWidth * MemoryLayout<Float>.stride
            zeros.withUnsafeBytes { ptr in
                for row in 0..<textureHeight {
                    let region = MTLRegion(
                        origin: MTLOrigin(x: 0, y: row, z: 0),
                        size: MTLSize(width: textureWidth, height: 1, depth: 1)
                    )
                    texture.replace(region: region, mipmapLevel: 0,
                                  withBytes: ptr.baseAddress!,
                                  bytesPerRow: bytesPerRow)
                }
            }
            SDRDebug.print("✅ Metal: Waterfall texture created and cleared (\(textureWidth)x\(textureHeight))")
        }
    }

    public func setColorScheme(named schemeName: String) {
        switch schemeName.lowercased() {
        case "thermal":
            colorScheme = .thermal
        case "grayscale":
            colorScheme = .grayscale
        default:
            colorScheme = .classic
        }
    }

    /// Add a new FFT row to the waterfall (called from main thread).
    /// Bins should be normalized 0.0–1.0.
    public func addWaterfallRow(_ bins: [Float]) {
        guard renderingActive, let texture = waterfallTexture, !bins.isEmpty else { return }

        // Resample bins to texture width
        var rowData: [Float]
        if bins.count == textureWidth {
            rowData = bins
        } else if bins.count > textureWidth {
            rowData = Array(bins.prefix(textureWidth))
        } else {
            // Interpolate bins to texture width
            rowData = [Float](repeating: 0, count: textureWidth)
            let scale = Float(bins.count - 1) / Float(textureWidth - 1)
            for i in 0..<textureWidth {
                let srcIdx = Float(i) * scale
                let idx = Int(srcIdx)
                let frac = srcIdx - Float(idx)
                let s0 = bins[min(idx, bins.count - 1)]
                let s1 = bins[min(idx + 1, bins.count - 1)]
                rowData[i] = s0 + (s1 - s0) * frac
            }
        }

        // Write row to texture at currentRow
        let region = MTLRegion(origin: MTLOrigin(x: 0, y: currentRow, z: 0),
                               size: MTLSize(width: textureWidth, height: 1, depth: 1))
        rowData.withUnsafeBytes { ptr in
            texture.replace(region: region, mipmapLevel: 0,
                          withBytes: ptr.baseAddress!,
                          bytesPerRow: textureWidth * MemoryLayout<Float>.stride)
        }

        currentRow = (currentRow + 1) % textureHeight
        scrollOffset = Float(currentRow) / Float(textureHeight)

        rowsWritten += 1
        if rowsWritten == 1 || rowsWritten % 200 == 0 {
            // Log first and every 200th row with sample values
            let minV = rowData.min() ?? 0
            let maxV = rowData.max() ?? 0
            let avgV = rowData.reduce(0, +) / Float(rowData.count)
            SDRDebug.print("🌊 Waterfall row \(rowsWritten): min=\(String(format: "%.3f", minV)) max=\(String(format: "%.3f", maxV)) avg=\(String(format: "%.3f", avgV)) bins=\(bins.count)")
        }
    }

    /// Update spectrum overlay bins (normalized 0.0–1.0).
    public func updateSpectrumBins(_ bins: [Float]) {
        spectrumLock.lock()
        defer { spectrumLock.unlock() }

        guard !bins.isEmpty else {
            spectrumSampleCount = 0
            return
        }

        let neededBytes = bins.count * MemoryLayout<Float>.stride
        if spectrumBuffer == nil || spectrumBufferCapacity < bins.count {
            // Grow buffer geometrically to avoid frequent reallocations.
            spectrumBufferCapacity = max(bins.count, max(1024, spectrumBufferCapacity * 2))
            spectrumBuffer = device.makeBuffer(
                length: spectrumBufferCapacity * MemoryLayout<Float>.stride,
                options: .storageModeShared
            )
        }

        if let spectrumBuffer {
            bins.withUnsafeBytes { src in
                spectrumBuffer.contents().copyMemory(from: src.baseAddress!, byteCount: neededBytes)
            }
            spectrumSampleCount = bins.count
        } else {
            spectrumSampleCount = 0
        }
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard renderingActive else { return }
        guard let drawable = view.currentDrawable,
              let renderPassDesc = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            return
        }

        // Draw waterfall
        if let pipeline = waterfallPipeline, let texture = waterfallTexture {
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)

            var uniforms = WaterfallUniforms(scrollOffset: scrollOffset, colorScheme: colorScheme.rawValue)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WaterfallUniforms>.stride, index: 0)

            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        // Draw spectrum overlay
        var localSpectrumBuffer: MTLBuffer?
        var localSpectrumCount = 0
        spectrumLock.lock()
        localSpectrumBuffer = spectrumBuffer
        localSpectrumCount = spectrumSampleCount
        spectrumLock.unlock()

        if showSpectrum, let pipeline = spectrumPipeline, let buffer = localSpectrumBuffer, localSpectrumCount > 0 {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            var count = UInt32(localSpectrumCount)
            encoder.setVertexBytes(&count, length: MemoryLayout<UInt32>.stride, index: 1)
            encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: localSpectrumCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        // FPS tracking
        frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastFPSTime >= 1.0 {
            currentFPS = Double(frameCount) / (now - lastFPSTime)
            frameCount = 0
            lastFPSTime = now
        }
    }
}
