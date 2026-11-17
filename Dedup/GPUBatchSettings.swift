import Foundation
import Metal
import Darwin

/// Starting values, not benchmark claims. Unknown devices use conservative limits.
struct GPUBatchRecommendation {
    static let choices=[64,128,256,512,1024]
    let chip:String
    let pairs:Int
    let byteBudget:Int
    let reason:String
    static func recommend(chip:String,memory:UInt64)->Self {
        let name=chip.lowercased(),gib=memory/(1024*1024*1024)
        let apple=name.contains("apple") && (name.contains("m1") || name.contains("m2") || name.contains("m3") || name.contains("m4") || name.contains("m5"))
        var pairs=128,mb=8
        if apple {
            if name.contains("ultra"){pairs=512;mb=32}
            else if name.contains("max"){pairs=512;mb=24}
            else if name.contains("pro"){pairs=256;mb=16}
            if gib<16{pairs=min(pairs,128);mb=min(mb,8)}
            else if gib<32{pairs=min(pairs,256);mb=min(mb,16)}
        }
        return Self(chip:chip,pairs:pairs,byteBudget:mb*1024*1024,
          reason:apple ? "按芯片系列与 \(gib) GB 内存给出的保守起始值，尚非测速最优值":"未识别芯片系列，使用保守起始值")
    }
    static var current:Self {
        var size=0
        var chip=""
        if sysctlbyname("machdep.cpu.brand_string",nil,&size,nil,0)==0 && size>0 {
            var bytes=[CChar](repeating:0,count:size)
            if sysctlbyname("machdep.cpu.brand_string",&bytes,&size,nil,0)==0{chip=String(cString:bytes)}
        }
        if chip.isEmpty{chip=MTLCreateSystemDefaultDevice()?.name ?? "未知芯片"}
        return recommend(chip:chip,memory:ProcessInfo.processInfo.physicalMemory)
    }
    static func validated(_ value:Int)->Int {choices.contains(value) ? value:128}
}
final class GPUBatchTelemetry:@unchecked Sendable {
    private let lock=NSLock();private var last=0,peak=0
    func record(_ count:Int){lock.lock();last=count;peak=max(peak,count);lock.unlock()}
    func text()->String{lock.lock();defer{lock.unlock()};return last>0 ? "实际 GPU 批次：最近 \(last) 对 · 本次最大 \(peak) 对":""}
}
