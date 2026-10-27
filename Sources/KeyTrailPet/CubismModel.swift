// Live2D C ABI declarations follow BongoCat's bindgen output at
// ayangweb/BongoCat b82b4750b776df1408db07d5858d37db1594c3f3 (Apache-2.0).
// Cubism Core and model assets are separately licensed and are not included here.
import Foundation
import Darwin
import simd
import KeyTrailIPC

struct PetFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// The helper consumes only the runtime's transient, coarse snapshot.
typealias PetSnapshot = PetState
extension PetState { static var idle: PetState { PetState(suspended: true) } }

final class CubismCore {
    typealias Count = @convention(c) (UnsafeRawPointer?) -> Int32
    typealias ArrayFunction = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
    typealias Update = @convention(c) (UnsafeMutableRawPointer?) -> Void
    let handle: UnsafeMutableRawPointer
    init(library: String?) throws {
        // Prefer the authorized official macOS dynamic library. A build may
        // alternatively force-load the SDK static archive and resolve exports
        // from its process handle by omitting the library path.
        guard let handle = dlopen(library, RTLD_NOW | RTLD_LOCAL) else {
            throw PetFailure("无法载入 Live2D 动画组件：\(String(cString: dlerror()))")
        }
        guard dlsym(handle, "csmReviveMocInPlace") != nil else {
            dlclose(handle)
            throw PetFailure("此构建缺少可用的 Live2D Cubism Core 动画组件。请重新安装包含官方 macOS 组件的 KeyTrail 开发构建。")
        }
        self.handle = handle
    }
    deinit { dlclose(handle) }
    func symbol<T>(_ name: String, as type: T.Type = T.self) throws -> T {
        guard let address = dlsym(handle, name) else { throw PetFailure("Live2D 组件缺少接口：\(name)") }
        return unsafeBitCast(address, to: T.self)
    }
    func optional<T>(_ name: String, as type: T.Type = T.self) -> T? {
        guard let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }
}

struct CatVertex { var position: SIMD2<Float>; var uv: SIMD2<Float> }
struct CatMesh {
    var vertices: [CatVertex]
    var indices: [UInt16]
    var texture: Int
    var order: Int
    var opacity: Float
    var flags: UInt8
    var visible: Bool
    var masks: [Int]
    var multiply: SIMD4<Float>
    var screen: SIMD4<Float>
}

final class CubismModel {
    let core: CubismCore
    let model: UnsafeMutableRawPointer
    private let mocStorage: UnsafeMutableRawPointer
    private let modelStorage: UnsafeMutableRawPointer
    let textureURLs: [URL]
    let backgroundURL: URL
    let keyboardOverlayURLs: [PetKeyboardKey: URL]
    let parameterNames: [String]
    private let parameterValues: UnsafeMutablePointer<Float>
    private let parameterMin: UnsafePointer<Float>
    private let parameterMax: UnsafePointer<Float>
    private let parameterDefaults: [Float]
    private let update: CubismCore.Update
    private let reset: CubismCore.Update
    private let arrays: [String: CubismCore.ArrayFunction]
    let drawableCount: Int
    let canvasSize: SIMD2<Float>
    let canvasOrigin: SIMD2<Float>
    let pixelsPerUnit: Float

    init(manifest: URL, library: String?) throws {
        let core = try CubismCore(library: library)
        self.core = core
        guard manifest.lastPathComponent.hasSuffix(".model3.json"),
              let root = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any],
              let files = root["FileReferences"] as? [String: Any],
              let mocName = files["Moc"] as? String,
              let textures = files["Textures"] as? [String], !textures.isEmpty, textures.count <= 32 else {
            throw PetFailure("请选择完整的 BongoCat .model3.json 模型；同目录应包含 moc3 和纹理文件。")
        }
        let directory = manifest.deletingLastPathComponent().resolvingSymlinksInPath()
        func asset(_ relative: String) throws -> URL {
            let url = directory.appendingPathComponent(relative).resolvingSymlinksInPath()
            guard !relative.hasPrefix("/"), url.path.hasPrefix(directory.path + "/"), FileManager.default.fileExists(atPath: url.path) else {
                throw PetFailure("模型资源缺失或超出所选目录：\(relative)")
            }
            return url
        }
        textureURLs = try textures.map(asset)
        backgroundURL = try asset("resources/background.png")
        keyboardOverlayURLs = Dictionary(uniqueKeysWithValues: PetKeyboardKey.allCases.compactMap { key in
            guard let url = try? asset("resources/left-keys/\(key.rawValue).png") else { return nil }
            return (key, url)
        })
        let data = try Data(contentsOf: asset(mocName))
        guard data.count > 16, data.count < 128 * 1024 * 1024 else { throw PetFailure("模型文件大小不受支持。") }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 64)
        data.copyBytes(to: storage.assumingMemoryBound(to: UInt8.self), count: data.count)
        typealias Consistency = @convention(c) (UnsafeMutableRawPointer?, UInt32) -> Int32
        typealias Revive = @convention(c) (UnsafeMutableRawPointer?, UInt32) -> UnsafeMutableRawPointer?
        typealias Size = @convention(c) (UnsafeRawPointer?) -> UInt32
        typealias Initialize = @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?, UInt32) -> UnsafeMutableRawPointer?
        var allocatedModel: UnsafeMutableRawPointer?
        do {
            let consistency: Consistency = try core.symbol("csmHasMocConsistency")
            guard consistency(storage, UInt32(data.count)) == 1 else { throw PetFailure("模型完整性校验失败，未载入动画。") }
            let revive: Revive = try core.symbol("csmReviveMocInPlace")
            guard let moc = revive(storage, UInt32(data.count)) else { throw PetFailure("此模型版本与 Live2D 组件不兼容。") }
            let size: Size = try core.symbol("csmGetSizeofModel")
            let bytes = size(moc)
            guard bytes > 0, bytes < 256 * 1024 * 1024 else { throw PetFailure("模型内存需求不受支持。") }
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: 16)
            allocatedModel = buffer
            let initialize: Initialize = try core.symbol("csmInitializeModelInPlace")
            guard let model = initialize(moc, buffer, bytes) else { throw PetFailure("无法初始化 Live2D 模型。") }
            self.model = model
            modelStorage = buffer
            mocStorage = storage
            if let offscreen: CubismCore.Count = core.optional("csmGetOffscreenCount"), offscreen(model) > 0 {
                throw PetFailure("此模型使用暂不支持的 Cubism 离屏混合。请选择标准 BongoCat 模型。")
            }
            let count: CubismCore.Count = try core.symbol("csmGetDrawableCount")
            drawableCount = Int(count(model))
            guard drawableCount > 0, drawableCount < 4096 else { throw PetFailure("模型绘制数量不受支持。") }
            let countParameters: CubismCore.Count = try core.symbol("csmGetParameterCount")
            let parameterCount = Int(countParameters(model))
            guard parameterCount >= 0, parameterCount < 8192 else { throw PetFailure("模型参数数量不受支持。") }
            func pointer<T>(_ name: String, _ type: T.Type) throws -> UnsafePointer<T> {
                let f: CubismCore.ArrayFunction = try core.symbol(name)
                guard let p = f(model) else { throw PetFailure("模型接口未返回数据：\(name)") }
                return p.assumingMemoryBound(to: type)
            }
            let ids = try pointer("csmGetParameterIds", UnsafePointer<CChar>?.self)
            parameterNames = (0..<parameterCount).map { ids[$0].map(String.init(cString:)) ?? "" }
            parameterValues = UnsafeMutablePointer(mutating: try pointer("csmGetParameterValues", Float.self))
            parameterMin = try pointer("csmGetParameterMinimumValues", Float.self)
            parameterMax = try pointer("csmGetParameterMaximumValues", Float.self)
            parameterDefaults = Array(UnsafeBufferPointer(start: try pointer("csmGetParameterDefaultValues", Float.self), count: parameterCount))
            guard parameterNames.contains("CatParamLeftHandDown"), parameterNames.contains("ParamMouseLeftDown") else {
                throw PetFailure("此模型没有标准 BongoCat 键盘与鼠标参数；当前仅支持标准猫模型。")
            }
            update = try core.symbol("csmUpdateModel")
            reset = try core.symbol("csmResetDrawableDynamicFlags")
            let names = ["csmGetDrawableConstantFlags", "csmGetDrawableDynamicFlags", "csmGetDrawableTextureIndices", "csmGetDrawableOpacities", "csmGetDrawableMaskCounts", "csmGetDrawableMasks", "csmGetDrawableVertexCounts", "csmGetDrawableVertexPositions", "csmGetDrawableVertexUvs", "csmGetDrawableIndexCounts", "csmGetDrawableIndices", "csmGetDrawableMultiplyColors", "csmGetDrawableScreenColors"]
            var functions: [String: CubismCore.ArrayFunction] = [:]
            for name in names { functions[name] = try core.symbol(name) }
            functions["orders"] = try core.optional("csmGetDrawableRenderOrders") ?? core.symbol("csmGetRenderOrders")
            arrays = functions
            if let blends: CubismCore.ArrayFunction = core.optional("csmGetDrawableBlendModes"), let raw = blends(model) {
                let values = raw.assumingMemoryBound(to: Int32.self)
                guard (0..<drawableCount).allSatisfy({ (0...2).contains(values[$0]) }) else {
                    throw PetFailure("此模型使用暂不支持的扩展混合模式。请选择标准 BongoCat 模型。")
                }
            }
            typealias Canvas = @convention(c) (UnsafeRawPointer?, UnsafeMutablePointer<Float>?, UnsafeMutablePointer<Float>?, UnsafeMutablePointer<Float>?) -> Void
            let readCanvas: Canvas = try core.symbol("csmReadCanvasInfo")
            var sizeXY = [Float](repeating: 0, count: 2), originXY = [Float](repeating: 0, count: 2), unit: Float = 0
            readCanvas(model, &sizeXY, &originXY, &unit)
            guard unit.isFinite, unit > 0, sizeXY.allSatisfy({ $0.isFinite && $0 > 0 }), originXY.allSatisfy(\.isFinite) else { throw PetFailure("模型画布参数无效。") }
            canvasSize = SIMD2(sizeXY[0], sizeXY[1]); canvasOrigin = SIMD2(originXY[0], originXY[1]); pixelsPerUnit = unit
        } catch {
            allocatedModel?.deallocate(); storage.deallocate(); throw error
        }
        update(model)
    }
    deinit { modelStorage.deallocate(); mocStorage.deallocate() }

    func supportedKeyboardKeys(_ state: PetSnapshot) -> [PetKeyboardKey] {
        guard state.enabled, !state.suspended, let keys = state.keyboardKeys else { return [] }
        return PetKeyboardKey.allCases.filter { keys.contains($0) && keyboardOverlayURLs[$0] != nil }.sorted { $0.rawValue < $1.rawValue }
    }

    func apply(_ state: PetSnapshot, keyboardOverlayReady: Bool = true) {
        for (index, value) in parameterDefaults.enumerated() { parameterValues[index] = value }
        func set(_ name: String, _ value: Float) {
            guard let i = parameterNames.firstIndex(of: name), value.isFinite else { return }
            parameterValues[i] = min(parameterMax[i], max(parameterMin[i], value))
        }
        let awake = state.enabled && !state.suspended
        // Hide the raised paw only when the corresponding original overlay can
        // actually be drawn. Legacy coarse pulses must never turn into Space.
        set("CatParamLeftHandDown", awake && keyboardOverlayReady && !supportedKeyboardKeys(state).isEmpty ? 1 : 0)
        let rightMouseButton = state.mouseButtonsMask & 2 != 0
        let leftMousePose = state.mouseButtonsMask & 1 != 0 || (!rightMouseButton && (state.rightPawHeld || state.rightPulseRemainingMs > 0))
        set("ParamMouseLeftDown", awake && leftMousePose ? 1 : 0)
        set("ParamMouseRightDown", awake && state.mouseButtonsMask & 2 != 0 ? 1 : 0)
        let x = awake ? Float(max(-1, min(1, state.gazeX))) : 0
        let y = awake ? Float(max(-1, min(1, state.gazeY))) : 0
        func normalized(_ name: String, _ value: Float) {
            guard let i = parameterNames.firstIndex(of: name) else { return }
            let neutral = parameterDefaults[i]
            set(name, neutral + value * (value >= 0 ? parameterMax[i] - neutral : neutral - parameterMin[i]))
        }
        normalized("ParamMouseX", x); normalized("ParamMouseY", y)
        normalized("ParamAngleX", x * 0.3); normalized("ParamAngleY", y * 0.3)
        normalized("ParamEyeBallX", x); normalized("ParamEyeBallY", y)
        update(model)
    }

    func meshes() throws -> [CatMesh] {
        func p<T>(_ name: String, _ type: T.Type) throws -> UnsafePointer<T> {
            guard let raw = arrays[name]?(model) else { throw PetFailure("模型绘制数据缺失：\(name)") }
            return raw.assumingMemoryBound(to: type)
        }
        let flags = try p("csmGetDrawableConstantFlags", UInt8.self), dynamic = try p("csmGetDrawableDynamicFlags", UInt8.self)
        let textures = try p("csmGetDrawableTextureIndices", Int32.self), order = try p("orders", Int32.self)
        let opacities = try p("csmGetDrawableOpacities", Float.self), maskCounts = try p("csmGetDrawableMaskCounts", Int32.self)
        let maskArrays = try p("csmGetDrawableMasks", UnsafePointer<Int32>?.self)
        let vertexCounts = try p("csmGetDrawableVertexCounts", Int32.self), indexCounts = try p("csmGetDrawableIndexCounts", Int32.self)
        let positions = try p("csmGetDrawableVertexPositions", UnsafePointer<Float>?.self)
        let uvs = try p("csmGetDrawableVertexUvs", UnsafePointer<Float>?.self)
        let indices = try p("csmGetDrawableIndices", UnsafePointer<UInt16>?.self)
        let multiply = try p("csmGetDrawableMultiplyColors", Float.self), screen = try p("csmGetDrawableScreenColors", Float.self)
        var result: [CatMesh] = []
        for i in 0..<drawableCount {
            let vc = Int(vertexCounts[i]), ic = Int(indexCounts[i]), mc = Int(maskCounts[i]), ti = Int(textures[i])
            guard vc >= 0, vc <= 65536, ic >= 0, ic <= 1_000_000, mc >= 0, mc <= drawableCount, textureURLs.indices.contains(ti), opacities[i].isFinite else { throw PetFailure("模型网格数据超出支持范围。") }
            guard (vc == 0 || positions[i] != nil && uvs[i] != nil), (ic == 0 || indices[i] != nil), (mc == 0 || maskArrays[i] != nil) else { throw PetFailure("模型网格指针缺失。") }
            // C csmVector2/4 are float structs aligned to 4 bytes. Read scalars
            // before constructing Swift SIMD values, which require more alignment.
            let vertices = (0..<vc).map { j in
                CatVertex(position: SIMD2(positions[i]![j * 2], positions[i]![j * 2 + 1]), uv: SIMD2(uvs[i]![j * 2], uvs[i]![j * 2 + 1]))
            }
            let multiplyColor = SIMD4(multiply[i * 4], multiply[i * 4 + 1], multiply[i * 4 + 2], multiply[i * 4 + 3])
            let screenColor = SIMD4(screen[i * 4], screen[i * 4 + 1], screen[i * 4 + 2], screen[i * 4 + 3])
            let indexList = ic == 0 ? [] : Array(UnsafeBufferPointer(start: indices[i]!, count: ic))
            let masks = mc == 0 ? [] : (0..<mc).map { Int(maskArrays[i]![$0]) }
            guard indexList.allSatisfy({ Int($0) < vc }), masks.allSatisfy({ (0..<drawableCount).contains($0) }), vertices.allSatisfy({ $0.position.x.isFinite && $0.position.y.isFinite && $0.uv.x.isFinite && $0.uv.y.isFinite }) else { throw PetFailure("模型网格索引或坐标无效。") }
            result.append(CatMesh(vertices: vertices, indices: indexList, texture: ti, order: Int(order[i]), opacity: max(0, min(1, opacities[i])), flags: flags[i], visible: dynamic[i] & 1 != 0, masks: masks, multiply: multiplyColor, screen: screenColor))
        }
        reset(model)
        return result
    }
}
