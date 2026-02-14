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
    private var waterfallRowScratch: [Float] = []

    // Smooth scrolling state
    private var lastRowUpdateTime: CFAbsoluteTime = 0
    // If > 0, use this fixed interval for interpolation (e.g. 1.0/12.0).
    // If 0, estimate from incoming data.
    public var expectedDataInterval: Double = 0.0
    private var estimatedRowInterval: Double = 0.0833

    // Spectrum interpolation state
    private var spectrumBuffers: [MTLBuffer?] = [nil, nil]
    private var spectrumBufferIndex: Int = 0
    private var lastSpectrumUpdateTime: CFAbsoluteTime = 0

    // Spectrum bins for overlay
    private let spectrumLock = NSLock()
    private var spectrumBufferCapacity: Int = 0
    private var spectrumSampleCount: Int = 0
    // Spectrum is rendered in a dedicated top view; keep waterfall clean.
    public var showSpectrum: Bool = true
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
        waterfallRowScratch = [Float](repeating: 0, count: textureWidth)

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
        if waterfallRowScratch.count != textureWidth {
            waterfallRowScratch = [Float](repeating: 0, count: textureWidth)
        }

        // Resample bins to texture width
        let useDirectBins = bins.count == textureWidth
        if useDirectBins {
            // No resampling needed.
        } else if bins.count > textureWidth {
            bins.withUnsafeBufferPointer { src in
                waterfallRowScratch.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.update(from: src.baseAddress!, count: textureWidth)
                }
            }
        } else {
            // Interpolate bins to texture width
            let scale = Float(bins.count - 1) / Float(textureWidth - 1)
            for i in 0..<textureWidth {
                let srcIdx = Float(i) * scale
                let idx = Int(srcIdx)
                let frac = srcIdx - Float(idx)
                let s0 = bins[min(idx, bins.count - 1)]
                let s1 = bins[min(idx + 1, bins.count - 1)]
                waterfallRowScratch[i] = s0 + (s1 - s0) * frac
            }
        }

        // Write row to texture at currentRow
        let region = MTLRegion(origin: MTLOrigin(x: 0, y: currentRow, z: 0),
                               size: MTLSize(width: textureWidth, height: 1, depth: 1))
        let bytesPerRow = textureWidth * MemoryLayout<Float>.stride
        if useDirectBins {
            bins.withUnsafeBytes { ptr in
                texture.replace(region: region, mipmapLevel: 0,
                                withBytes: ptr.baseAddress!,
                                bytesPerRow: bytesPerRow)
            }
        } else {
            waterfallRowScratch.withUnsafeBytes { ptr in
                texture.replace(region: region, mipmapLevel: 0,
                                withBytes: ptr.baseAddress!,
                                bytesPerRow: bytesPerRow)
            }
        }

        let now = CFAbsoluteTimeGetCurrent()
        if lastRowUpdateTime > 0 {
            let delta = now - lastRowUpdateTime
            // Only update estimate if we don't have a fixed expected interval
            if expectedDataInterval <= 0 {
                // Simple exponential moving average for interval estimation
                estimatedRowInterval = estimatedRowInterval * 0.9 + delta * 0.1
            } else {
                estimatedRowInterval = expectedDataInterval
            }
        }
        lastRowUpdateTime = now

        currentRow = (currentRow + 1) % textureHeight
        scrollOffset = Float(currentRow) / Float(textureHeight)

        rowsWritten += 1
        if rowsWritten == 1 || rowsWritten % 200 == 0 {
            // Log first and every 200th row with sample values
            let loggedBins = useDirectBins ? bins : waterfallRowScratch
            SDRDebug.print(
                "🌊 Waterfall row \(rowsWritten): min=\(String(format: "%.3f", loggedBins.min() ?? 0)) " +
                "max=\(String(format: "%.3f", loggedBins.max() ?? 0)) " +
                "avg=\(String(format: "%.3f", loggedBins.reduce(0, +) / Float(loggedBins.count))) bins=\(bins.count)"
            )
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

        lastSpectrumUpdateTime = CFAbsoluteTimeGetCurrent()
        let neededBytes = bins.count * MemoryLayout<Float>.stride
        
        // Check capacity for BOTH buffers
        if spectrumBuffers[0] == nil || spectrumBuffers[1] == nil || spectrumBufferCapacity < bins.count {
            spectrumBufferCapacity = max(bins.count, max(1024, spectrumBufferCapacity * 2))
            // Reallocate both buffers to ensure consistent size
            spectrumBuffers[0] = device.makeBuffer(length: spectrumBufferCapacity * MemoryLayout<Float>.stride, options: .storageModeShared)
            spectrumBuffers[1] = device.makeBuffer(length: spectrumBufferCapacity * MemoryLayout<Float>.stride, options: .storageModeShared)
            
            // If completely new, clear both so we don't interpolate from garbage
            if let b0 = spectrumBuffers[0], let b1 = spectrumBuffers[1] {
                b0.contents().initializeMemory(as: UInt8.self, repeating: 0, count: neededBytes)
                b1.contents().initializeMemory(as: UInt8.self, repeating: 0, count: neededBytes)
            }
        }
        
        // Swap index: current becomes previous
        let nextIndex = (spectrumBufferIndex + 1) % 2
        
        if let targetBuffer = spectrumBuffers[nextIndex] {
            bins.withUnsafeBytes { src in
                targetBuffer.contents().copyMemory(from: src.baseAddress!, byteCount: neededBytes)
            }
            spectrumSampleCount = bins.count
            spectrumBufferIndex = nextIndex
        } else {
            spectrumSampleCount = 0
        }
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        let desiredFPS = max(1, targetFPS)
        if view.preferredFramesPerSecond != desiredFPS {
            view.preferredFramesPerSecond = desiredFPS
        }

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

            // Calculate smooth scroll offset based on time since last row update
            let now = CFAbsoluteTimeGetCurrent()
            let timeSinceLastUpdate = now - lastRowUpdateTime
            let rowFraction = min(1.0, timeSinceLastUpdate / max(0.001, estimatedRowInterval))
            let visualScrollOffset = (scrollOffset + Float(rowFraction) / Float(textureHeight)).truncatingRemainder(dividingBy: 1.0)

            var uniforms = WaterfallUniforms(scrollOffset: visualScrollOffset, colorScheme: colorScheme.rawValue)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WaterfallUniforms>.stride, index: 0)

            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        // Draw spectrum overlay (currently disabled for waterfall view).
        if showSpectrum {
            var currentBuffer: MTLBuffer?
            var prevBuffer: MTLBuffer?
            var localSpectrumCount = 0
            var interpFactor: Float = 0

            spectrumLock.lock()
            let currIdx = spectrumBufferIndex
            let prevIdx = (currIdx + 1) % 2 // previous is the OTHER index
            
            currentBuffer = spectrumBuffers[currIdx]
            prevBuffer = spectrumBuffers[prevIdx]
            localSpectrumCount = spectrumSampleCount
            
            let timeSinceUpdate = CFAbsoluteTimeGetCurrent() - lastSpectrumUpdateTime
            // Calculate interpolation factor
            let interval = (expectedDataInterval > 0) ? expectedDataInterval : max(0.001, estimatedRowInterval)
            interpFactor = Float(min(1.0, timeSinceUpdate / interval))
            spectrumLock.unlock()

            if let pipeline = spectrumPipeline, let curr = currentBuffer, let prev = prevBuffer, localSpectrumCount > 0 {
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(curr, offset: 0, index: 0)
                encoder.setVertexBuffer(prev, offset: 0, index: 1)
                
                var count = UInt32(localSpectrumCount)
                encoder.setVertexBytes(&count, length: MemoryLayout<UInt32>.stride, index: 2)
                encoder.setVertexBytes(&interpFactor, length: MemoryLayout<Float>.stride, index: 3)
                
                encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: localSpectrumCount)
            }
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
