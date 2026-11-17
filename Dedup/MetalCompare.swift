import Foundation
import Metal

final class CancellableCommandCompletion {
    private let semaphore=DispatchSemaphore(value:0)
    func signal(){semaphore.signal()}
    func wait(cancelled:()->Bool)throws {
        while true {
            if cancelled(){throw CancellationError()}
            if semaphore.wait(timeout:.now()+0.02) == .success {break}
        }
        if cancelled(){throw CancellationError()}
    }
}

struct AudioPair { let first: Int; let second: Int }
struct PairScore { let score: Float; let offset: Int }

/// Bounded batches keep the GPU working set independent of the entire music library.
final class MetalCompare {
    static var deviceName: String? { MTLCreateSystemDefaultDevice()?.name }
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private struct Track { var base: UInt32; var count: UInt32 }
    private struct Pair { var a: UInt32; var b: UInt32 }
    private struct Output { var score: Float; var offset: Int32 }

    init() throws {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { throw AudioError.message("本机没有可用的 Metal GPU") }
        device = d; queue = q
        let options = MTLCompileOptions(); options.fastMathEnabled = false
        let lib = try d.makeLibrary(source: Self.shader, options: options)
        guard let function = lib.makeFunction(name: "comparePairs") else { throw AudioError.message("GPU 比对程序初始化失败") }
        pipeline = try d.makeComputePipelineState(function: function)
        guard pipeline.maxTotalThreadsPerThreadgroup >= 64 else { throw AudioError.message("GPU 不支持所需的计算规模") }
    }
    func compare(_ songs: [SongPrint], pairs: [AudioPair],cancelled:()->Bool = {false}) throws -> [PairScore] {
        if cancelled(){throw CancellationError()}
        guard !pairs.isEmpty else { return [] }
        var local = [Int:UInt32](); var tracks = [Track](); var features = [Float]()
        var packedPairs = [Pair](); packedPairs.reserveCapacity(pairs.count)
        func index(_ global: Int) throws -> UInt32 {
            if let known = local[global] { return known }
            if cancelled(){throw CancellationError()}
            let song = songs[global]
            guard song.frames.count >= 6, song.frames.allSatisfy({$0.count == 48}) else { throw AudioError.message("频谱缓存格式不兼容，请清除指纹缓存后重新扫描") }
            guard features.count + song.frames.count * 48 <= min(device.maxBufferLength / 4, 16*1024*1024) else {throw AudioError.message("长音频批次超出 GPU 工作内存限制，将使用 CPU")}
            let i = UInt32(tracks.count); local[global] = i
            tracks.append(Track(base:UInt32(features.count),count:UInt32(song.frames.count)))
            for (i,frame) in song.frames.enumerated() {if i%64==0 && cancelled(){throw CancellationError()};features.append(contentsOf:frame)}
            return i
        }
        for pair in pairs { packedPairs.append(Pair(a:try index(pair.first),b:try index(pair.second))) }
        func buffer<T>(_ values: [T]) throws -> MTLBuffer {
            let bytes = values.count * MemoryLayout<T>.stride
            guard bytes > 0, bytes <= device.maxBufferLength else { throw AudioError.message("本批次超出 GPU 内存限制") }
            let result = values.withUnsafeBytes { ptr in device.makeBuffer(bytes:ptr.baseAddress!,length:bytes,options:.storageModeShared) }
            guard let b = result else { throw AudioError.message("GPU 内存不足") }; return b
        }
        let f = try buffer(features), t = try buffer(tracks), p = try buffer(packedPairs)
        guard let out = device.makeBuffer(length:pairs.count * MemoryLayout<Output>.stride,options:.storageModeShared),
              let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw AudioError.message("无法创建 GPU 比对任务") }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(f,offset:0,index:0); encoder.setBuffer(t,offset:0,index:1)
        encoder.setBuffer(p,offset:0,index:2); encoder.setBuffer(out,offset:0,index:3)
        encoder.dispatchThreadgroups(MTLSize(width:pairs.count,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:64,height:1,depth:1))
        encoder.endEncoding()
        if cancelled(){throw CancellationError()}
        let signal=CancellableCommandCompletion()
        let resources:[MTLBuffer]=[f,t,p,out]
        command.addCompletedHandler{_ in _=resources.count;signal.signal()}
        command.commit()
        // A committed Metal command cannot be forcibly cancelled. Keep its buffers
        // alive via completion, but release the scan worker promptly on stop.
        try signal.wait(cancelled:cancelled)
        guard command.status == .completed else { throw command.error ?? AudioError.message("GPU 比对任务失败") }
        let ptr = out.contents().bindMemory(to:Output.self,capacity:pairs.count)
        return (0..<pairs.count).map { PairScore(score:ptr[$0].score,offset:Int(ptr[$0].offset)) }
    }

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Track { uint base; uint count; };
    struct Pair { uint a; uint b; };
    struct Output { float score; int offset; };
    kernel void comparePairs(device const float* f [[buffer(0)]],
                             device const Track* tracks [[buffer(1)]],
                             device const Pair* pairs [[buffer(2)]],
                             device Output* result [[buffer(3)]],
                             uint group [[threadgroup_position_in_grid]],
                             uint lane [[thread_index_in_threadgroup]]) {
        threadgroup float scores[64];
        threadgroup int offsets[64];
        float score = -1.0f; int offset = int(lane) - 20;
        if (lane < 41) {
            Track a = tracks[pairs[group].a], b = tracks[pairs[group].b];
            int sa = max(0,-offset), sb = max(0,offset);
            int overlap = min(int(a.count)-sa,int(b.count)-sb);
            int required = max(6,int(float(min(a.count,b.count))*0.75f));
            if (overlap >= required) {
                float spectral = 0.0f, changes = 0.0f; int valid = 0;
                for (int frame=0; frame<overlap; ++frame) {
                    uint ia = a.base + uint(sa+frame)*48;
                    uint ib = b.base + uint(sb+frame)*48;
                    float dot=0.0f, dd=0.0f, aa=0.0f, bb=0.0f;
                    for (uint band=0; band<48; ++band) {
                        float x=f[ia+band], y=f[ib+band];
                        dot += x*y;
                        if (frame>0) {
                            float dx=x-f[ia-48+band], dy=y-f[ib-48+band];
                            dd+=dx*dy; aa+=dx*dx; bb+=dy*dy;
                        }
                    }
                    spectral += dot;
                    if (frame>0) {
                        float ma=sqrt(aa), mb=sqrt(bb);
                        if (ma>0.015f && mb>0.015f) { changes += dd/(ma*mb); valid++; }
                    }
                }
                float shape=spectral/float(overlap);
                float movement=valid>=max(3,overlap/5) ? max(0.0f,changes/float(valid)) : 0.0f;
                score=clamp(shape*0.55f + movement*0.45f,0.0f,1.0f);
            }
        }
        scores[lane]=score; offsets[lane]=offset;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        // Prefer the earliest offset when scores tie, matching the CPU loop.
        for (uint stride=32;stride>0;stride/=2) {
            if (lane<stride) {
                float s=scores[lane+stride]; int o=offsets[lane+stride];
                if (s>scores[lane] || (s==scores[lane] && o<offsets[lane])) {
                    scores[lane]=s; offsets[lane]=o;
                }
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (lane==0) { result[group].score=scores[0]; result[group].offset=offsets[0]; }
    }
    """
}
