// Metal rendering adapted from ayangweb/BongoCat, commit
// b82b4750b776df1408db07d5858d37db1594c3f3, Apache-2.0:
// crates/bongocat-overlay/src/macos/{pipelines,renderer}.rs.
// Changes: Swift implementation, standard BongoCat-only Core model, AppKit host,
// bounded per-frame resources; no upstream input, plugins, network or updater.
import AppKit
import Metal
import QuartzCore
import ImageIO
import simd
import KeyTrailIPC

private struct CatUniforms {
    var transform: SIMD4<Float>
    var multiply: SIMD4<Float>
    var screen: SIMD4<Float>
    var mask: SIMD4<Float>
    var settings: SIMD4<Float> // x: opacity, yzw reserved
}

/// At most one current request and one worker are retained. New snapshots
/// replace the pending set; no key-event queue or input history is constructed.
/// The 12-entry cache contains static asset pixels, not captured input.
private final class KeyboardOverlayCache {
    private let urls: [PetKeyboardKey: URL]
    private let device: MTLDevice
    private let worker = DispatchQueue(label: "com.auriel.keytrail.pet.keyboard-images", qos: .userInitiated)
    private let lock = NSLock()
    private var wanted: [PetKeyboardKey] = []
    private var generation: UInt64 = 0
    private var working = false
    private var ready: (keys: [PetKeyboardKey], texture: MTLTexture)?
    private var failure: String?
    private var revision: UInt64 = 0
    // These fields are confined to the worker queue.
    private var images: [PetKeyboardKey: CGImage] = [:]
    private var recent: [PetKeyboardKey] = []
    private var badImages: [PetKeyboardKey: String] = [:]
    init(urls: [PetKeyboardKey: URL], device: MTLDevice) { self.urls = urls; self.device = device }
    func request(_ keys: [PetKeyboardKey]) {
        lock.lock()
        guard keys != wanted else { lock.unlock(); return }
        wanted = keys; generation &+= 1; failure = nil
        // Drop an obsolete GPU overlay immediately; only the current result is kept.
        ready = nil; revision &+= 1
        guard !keys.isEmpty, !working else { lock.unlock(); return }
        working = true; lock.unlock()
        worker.async { [weak self] in self?.runLatest() }
    }
    func result(for keys: [PetKeyboardKey], wait: Bool = false) -> MTLTexture? {
        request(keys)
        // CLI synthetic exports explicitly wait for this queue; live rendering
        // never blocks the main thread on image IO or decoding.
        if wait { worker.sync {} }
        lock.lock(); defer { lock.unlock() }
        return ready?.keys == keys ? ready?.texture : nil
    }
    var presentationRevision: UInt64 { lock.lock(); defer { lock.unlock() }; return revision }
    var error: String? { lock.lock(); defer { lock.unlock() }; return failure }
    private func runLatest() {
        while true {
            lock.lock(); let keys = wanted; let token = generation
            if keys.isEmpty { working = false; lock.unlock(); return }
            lock.unlock()
            let result: Result<MTLTexture, Error> = autoreleasepool { Result { try compose(keys) } }
            lock.lock()
            if generation != token { lock.unlock(); continue }
            switch result {
            case .success(let texture): ready = (keys, texture); failure = nil
            case .failure(let error): ready = nil; failure = error.localizedDescription
            }
            revision &+= 1; working = false; lock.unlock(); return
        }
    }
    private func image(for key: PetKeyboardKey) throws -> CGImage {
        if let message = badImages[key] { throw PetFailure(message) }
        recent.removeAll { $0 == key }; recent.append(key)
        if let image = images[key] { return image }
        do {
            guard let url = urls[key], let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  sourceImage.width == 612, sourceImage.height == 354,
                  let context = CGContext(data: nil, width: 612, height: 354, bitsPerComponent: 8, bytesPerRow: 612 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw PetFailure("键位素材缺失或尺寸不匹配：\(key.rawValue)")
            }
            context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: 612, height: 354))
            guard let decoded = context.makeImage() else { throw PetFailure("无法解码键位素材：\(key.rawValue)") }
            // Evict before inserting, so even many held keys never retain all 53 images.
            while images.count >= 12, let oldest = recent.first(where: { images[$0] != nil }) {
                images.removeValue(forKey: oldest); recent.removeAll { $0 == oldest }
            }
            images[key] = decoded
            return decoded
        } catch { badImages[key] = error.localizedDescription; throw error }
    }
    private func compose(_ keys: [PetKeyboardKey]) throws -> MTLTexture {
        guard let context = CGContext(data: nil, width: 612, height: 354, bitsPerComponent: 8, bytesPerRow: 612 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw PetFailure("无法创建键位叠层。") }
        for key in keys { context.draw(try image(for: key), in: CGRect(x: 0, y: 0, width: 612, height: 354)) }
        guard let image = context.makeImage() else { throw PetFailure("无法合成键位叠层。") }
        return try CatMetalRenderer.texture(image: image, device: device)
    }
}

final class CatMetalRenderer {
    let layer: CAMetalLayer
    let model: CubismModel
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: [MTLRenderPipelineState]
    private let maskPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let textures: [MTLTexture]
    private let backgroundTexture: MTLTexture
    private let keyboardOverlays: KeyboardOverlayCache
    private var masks: [String: MTLTexture] = [:]
    private var lastSize = SIMD2<Int>(0, 0)
    private let available = DispatchSemaphore(value: 1)
    private let errorLock = NSLock()
    private var gpuError: String?

    init(model: CubismModel, layer: CAMetalLayer) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw PetFailure("此 Mac 无法创建 Metal 绘图设备。") }
        self.device = device; self.queue = queue; self.model = model; self.layer = layer
        layer.device = device; layer.pixelFormat = .bgra8Unorm; layer.isOpaque = false
        layer.framebufferOnly = true; layer.presentsWithTransaction = false; layer.allowsNextDrawableTimeout = true
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        func pipeline(_ mode: Int, mask: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "cat_vertex")
            d.fragmentFunction = library.makeFunction(name: mask ? "cat_mask" : "cat_fragment")
            let a = d.colorAttachments[0]!
            a.pixelFormat = .bgra8Unorm; a.isBlendingEnabled = true
            a.sourceRGBBlendFactor = mode == 2 ? .destinationColor : .one
            a.destinationRGBBlendFactor = mode == 1 ? .one : .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = mode == 0 ? .one : .zero
            a.destinationAlphaBlendFactor = mode == 0 ? .oneMinusSourceAlpha : .one
            return try device.makeRenderPipelineState(descriptor: d)
        }
        pipelines = try (0...2).map { try pipeline($0) }
        maskPipeline = try pipeline(0, mask: true)
        let s = MTLSamplerDescriptor(); s.minFilter = .linear; s.magFilter = .linear
        s.sAddressMode = .clampToEdge; s.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: s) else { throw PetFailure("无法创建纹理采样器。") }
        self.sampler = sampler
        textures = try model.textureURLs.map { try Self.texture(url: $0, device: device) }
        backgroundTexture = try Self.texture(url: model.backgroundURL, device: device)
        keyboardOverlays = KeyboardOverlayCache(urls: model.keyboardOverlayURLs, device: device)
        // Validate the model immediately, before presenting a transparent panel.
        _ = try model.meshes()
    }

    private static func texture(url: URL, device: MTLDevice) throws -> MTLTexture {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0, image.width <= 8192, image.height <= 8192 else { throw PetFailure("无法读取模型纹理：\(url.lastPathComponent)") }
        return try texture(image: image, device: device)
    }

    fileprivate static func texture(image: CGImage, device: MTLDevice) throws -> MTLTexture {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw PetFailure("无法解码模型纹理。") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // CoreGraphics yields premultiplied pixels; the Cubism shader expects
        // straight source RGB and premultiplies once after color/mask/opacity.
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[i + 3])
            if alpha > 0 && alpha < 255 {
                for c in 0..<3 { pixels[i + c] = UInt8(min(255, (Int(pixels[i + c]) * 255 + alpha / 2) / alpha)) }
            }
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead; d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else { throw PetFailure("模型纹理内存不足。") }
        pixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        return texture
    }

    func prepareKeyboard(_ snapshot: PetSnapshot) { keyboardOverlays.request(model.supportedKeyboardKeys(snapshot)) }
    var keyboardPresentationRevision: UInt64 { keyboardOverlays.presentationRevision }
    func keyboardStatus(_ snapshot: PetSnapshot) -> String? {
        if snapshot.keyboardKeys == nil { return "后台版本不支持实际键位，请更新并重新打开 KeyTrail。" }
        if let keys = snapshot.keyboardKeys, keys.contains(where: { model.keyboardOverlayURLs[$0] == nil }) { return "部分键位素材缺失；未用其他键替代，请重新安装完整资源。" }
        return keyboardOverlays.error
    }

    func draw(_ snapshot: PetSnapshot) throws -> Bool {
        guard let drawable = layer.nextDrawable() else { return false }
        return try render(snapshot, target: drawable.texture, drawable: drawable)
    }

    func checkFailure() throws {
        errorLock.lock(); let previousError = gpuError; errorLock.unlock()
        if let previousError { throw PetFailure(previousError) }
    }

    /// Synthetic offscreen evidence uses exactly the same meshes, mask passes,
    /// shaders and blending as the live panel. It never reads system input.
    func renderPNG(_ snapshot: PetSnapshot, to url: URL) throws {
        let width = 640
        let height = min(1024, max(256, Int(Float(width) * model.canvasSize.y / model.canvasSize.x)))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d) else { throw PetFailure("无法创建离屏验证纹理。") }
        guard try render(snapshot, target: target, drawable: nil, wait: true) else { throw PetFailure("离屏绘图通道正忙，请重试。") }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw PetFailure("无法保存离屏验证图片。") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PetFailure("离屏验证图片写入失败。") }
    }

    private func render(_ snapshot: PetSnapshot, target: MTLTexture, drawable: CAMetalDrawable?, wait: Bool = false) throws -> Bool {
        try checkFailure()
        guard available.wait(timeout: wait ? .now() + 2 : .now()) == .success else {
            if wait { throw PetFailure("上一帧 Metal 绘图未及时完成。") }
            return false
        }
        var submitted = false
        defer { if !submitted { available.signal() } }
        guard let command = queue.makeCommandBuffer() else { throw PetFailure("无法创建 Metal 指令缓冲区。") }
        let supportedKeys = model.supportedKeyboardKeys(snapshot)
        let keyboardTexture = keyboardOverlays.result(for: supportedKeys, wait: wait)
        if wait, !supportedKeys.isEmpty, keyboardTexture == nil {
            throw PetFailure(keyboardOverlays.error ?? "键位叠层尚未准备完成。")
        }
        model.apply(snapshot, keyboardOverlayReady: keyboardTexture != nil)
        let meshes = try model.meshes()
        let width = target.width, height = target.height
        let size = SIMD2(width, height)
        if size != lastSize { masks.removeAll(); lastSize = size }
        let canvas = model.canvasSize / model.pixelsPerUnit
        let origin = model.canvasOrigin / model.pixelsPerUnit
        let fitting = min(Float(width) / canvas.x, Float(height) / canvas.y) * 0.96
        let scale = SIMD2(2 * fitting / Float(width), 2 * fitting / Float(height))
        let center = SIMD2(canvas.x / 2 - origin.x, origin.y - canvas.y / 2)
        let transform = SIMD4(scale.x, scale.y, -center.x * scale.x, -center.y * scale.y)
        struct Buffers { var vertices: MTLBuffer; var indices: MTLBuffer }
        var buffers: [Buffers?] = []
        for mesh in meshes {
            if mesh.vertices.isEmpty || mesh.indices.isEmpty { buffers.append(nil); continue }
            let vb = mesh.vertices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            let ib = mesh.indices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            guard let vb, let ib else { throw PetFailure("绘图缓冲区内存不足。") }
            buffers.append(Buffers(vertices: vb, indices: ib))
        }
        func drawMesh(_ index: Int, _ encoder: MTLRenderCommandEncoder, uniforms: CatUniforms) {
            guard let b = buffers[index] else { return }
            let mesh = meshes[index]
            var u = uniforms
            encoder.setVertexBuffer(b.vertices, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<CatUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<CatUniforms>.stride, index: 1)
            encoder.setFragmentTexture(textures[mesh.texture], index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.setFrontFacing(.counterClockwise)
            encoder.setCullMode(mesh.flags & 4 != 0 ? .none : .back)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indices.count, indexType: .uint16, indexBuffer: b.indices, indexBufferOffset: 0)
        }
        func pass(_ texture: MTLTexture) -> MTLRenderPassDescriptor {
            let p = MTLRenderPassDescriptor(); let a = p.colorAttachments[0]!
            a.texture = texture; a.loadAction = .clear; a.storeAction = .store
            a.clearColor = MTLClearColorMake(0, 0, 0, 0)
            return p
        }
        var renderedMasks = Set<String>()
        for mesh in meshes where !mesh.masks.isEmpty && mesh.visible {
            let key = mesh.masks.sorted().map(String.init).joined(separator: ",")
            guard renderedMasks.insert(key).inserted else { continue }
            if masks[key] == nil {
                guard masks.count < 64 else { throw PetFailure("模型裁剪组数量超出支持范围。") }
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
                guard let t = device.makeTexture(descriptor: d) else { throw PetFailure("裁剪纹理内存不足。") }
                masks[key] = t
            }
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass(masks[key]!)) else { throw PetFailure("无法创建裁剪绘图通道。") }
            encoder.setRenderPipelineState(maskPipeline)
            // Masks intentionally use source geometry/texture even when the
            // source drawable is hidden; drawable opacity does not affect mask.
            for source in mesh.masks {
                drawMesh(source, encoder, uniforms: CatUniforms(transform: transform, multiply: SIMD4(repeating: 1), screen: .zero, mask: .zero, settings: SIMD4(1, 0, 0, 0)))
            }
            encoder.endEncoding()
        }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass(target)) else { throw PetFailure("无法创建模型绘图通道。") }
        // The upstream standard cat keeps its keyboard in a separate background
        // asset. Fit it to the same canvas and draw it behind the Live2D paws.
        let backgroundVertices = [
            CatVertex(position: SIMD2(-origin.x, origin.y), uv: SIMD2(0, 1)),
            CatVertex(position: SIMD2(-origin.x, origin.y - canvas.y), uv: SIMD2(0, 0)),
            CatVertex(position: SIMD2(canvas.x - origin.x, origin.y), uv: SIMD2(1, 1)),
            CatVertex(position: SIMD2(canvas.x - origin.x, origin.y - canvas.y), uv: SIMD2(1, 0))
        ]
        var backgroundUniforms = CatUniforms(transform: transform, multiply: SIMD4(repeating: 1),
                                           screen: .zero, mask: .zero, settings: SIMD4(1, 0, 0, 0))
        func drawCanvasTexture(_ texture: MTLTexture) {
            encoder.setRenderPipelineState(pipelines[0]); encoder.setCullMode(.none)
            backgroundVertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            encoder.setVertexBytes(&backgroundUniforms, length: MemoryLayout<CatUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&backgroundUniforms, length: MemoryLayout<CatUniforms>.stride, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentTexture(texture, index: 1)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        drawCanvasTexture(backgroundTexture)
        for i in meshes.indices.sorted(by: { meshes[$0].order < meshes[$1].order }) {
            let mesh = meshes[i]
            guard mesh.visible, mesh.opacity > 0 else { continue }
            let mode = mesh.flags & 1 != 0 ? 1 : (mesh.flags & 2 != 0 ? 2 : 0)
            encoder.setRenderPipelineState(pipelines[mode])
            let key = mesh.masks.sorted().map(String.init).joined(separator: ",")
            // A bound texture is required even on the branch without a mask.
            encoder.setFragmentTexture(masks[key] ?? textures[0], index: 1)
            let uniform = CatUniforms(transform: transform, multiply: mesh.multiply, screen: mesh.screen, mask: SIMD4(Float(width), Float(height), mesh.masks.isEmpty ? 0 : 1, mesh.flags & 8 != 0 ? 1 : 0), settings: SIMD4(mesh.opacity, 0, 0, 0))
            drawMesh(i, encoder, uniforms: uniform)
        }
        // Only the exact current, supported key set may replace the raised paw.
        // Pending/stale/legacy sets never fall back to a fabricated Space press.
        if let keyboardTexture { drawCanvasTexture(keyboardTexture) }
        encoder.endEncoding()
        if let drawable { command.present(drawable) }
        command.addCompletedHandler { [weak self, available] completed in
            if let self, let error = completed.error {
                self.errorLock.lock(); self.gpuError = "Metal 绘图失败：\(error.localizedDescription)"; self.errorLock.unlock()
            }
            available.signal()
        }
        submitted = true; command.commit()
        if wait {
            command.waitUntilCompleted()
            if let error = command.error { throw PetFailure("Metal 离屏绘图失败：\(error.localizedDescription)") }
        }
        return true
    }

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float2 position; float2 uv; };
    struct Uniforms { float4 transform; float4 multiply; float4 screen; float4 mask; float4 settings; };
    struct Raster { float4 position [[position]]; float2 uv; };
    vertex Raster cat_vertex(const device Vertex* vertices [[buffer(0)]], constant Uniforms& u [[buffer(1)]], uint id [[vertex_id]]) {
        Raster r; r.position = float4(vertices[id].position * u.transform.xy + u.transform.zw, 0, 1);
        r.uv = float2(vertices[id].uv.x, 1.0 - vertices[id].uv.y); return r;
    }
    fragment float4 cat_fragment(Raster r [[stage_in]], texture2d<float> tex [[texture(0)]], texture2d<float> mask [[texture(1)]], sampler s [[sampler(0)]], constant Uniforms& u [[buffer(1)]]) {
        float4 t = tex.sample(s, r.uv);
        float3 c = t.rgb * u.multiply.rgb;
        c = c + u.screen.rgb - c * u.screen.rgb;
        float coverage = 1;
        if (u.mask.z > 0.5) { coverage = mask.sample(s, r.position.xy / u.mask.xy).a; if (u.mask.w > 0.5) coverage = 1 - coverage; }
        float alpha = t.a * u.settings.x * coverage;
        return float4(c * alpha, alpha);
    }
    fragment float4 cat_mask(Raster r [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        return float4(0, 0, 0, tex.sample(s, r.uv).a);
    }
    """
}
