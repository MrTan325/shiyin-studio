import Foundation
import Accelerate

/// Streaming FFT preserves windows across input chunks; PCM memory stays bounded.
final class SpectrumAccumulator {
    let n = 2048, hop = 1024, bands = 48
    let setup: FFTSetup
    var window = [Float](repeating:0,count:2048)
    let bounds = (0...48).map { Int(80 * pow(3800.0/80,Double($0)/48) * 2048/8000) }
    var real=[Float](repeating:0,count:2048),imaginary=[Float](repeating:0,count:2048),power=[Float](repeating:0,count:1024)
    var pending = [Float]()
    var absoluteStart = 0
    var bucketSecond = 0
    var bucket = [Float](repeating:0,count:48)
    var aggregate = [Float](repeating:0,count:48)
    var bucketCount = 0, total = 0
    var frames = [[Float]]()
    let engine = AudioEngine()
    init() throws {
        guard let value = vDSP_create_fftsetup(11,FFTRadix(kFFTRadix2)) else { throw AudioError.message("频谱初始化失败") }
        setup = value
        vDSP_hann_window(&window,2048,Int32(vDSP_HANN_NORM))
    }
    deinit { vDSP_destroy_fftsetup(setup) }
    func append(_ samples:[Float],cancelled:()->Bool = {false}) throws {
        pending.append(contentsOf:samples)
        var offset=0
        while offset+n <= pending.count {
            if cancelled() {throw CancellationError()}
            let second=(absoluteStart+offset)/8000
            if second != bucketSecond && bucketCount>0 { flush();bucketSecond=second }
            for i in 0..<n {real[i]=pending[offset+i]*window[i];imaginary[i]=0}
            real.withUnsafeMutableBufferPointer { re in imaginary.withUnsafeMutableBufferPointer { im in
                var split=DSPSplitComplex(realp:re.baseAddress!,imagp:im.baseAddress!)
                vDSP_fft_zip(setup,&split,1,11,FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split,1,&power,1,1024)
            } }
            for band in 0..<bands {
                let lo=max(1,bounds[band]),hi=min(n/2,max(bounds[band]+1,bounds[band+1]))
                var energy:Float=0
                for bin in lo..<hi {energy+=power[bin]}
                let value=log10(max(energy/Float(hi-lo),0.00000001))
                bucket[band]+=value;aggregate[band]+=value
            }
            total+=1;bucketCount+=1;offset+=hop
        }
        if offset>0 {pending=Array(pending[offset...]);absoluteStart+=offset}
    }
    private func flush() {
        frames.append(engine.normalize(bucket.map{$0/Float(bucketCount)}))
        bucket=[Float](repeating:0,count:48);bucketCount=0
    }
    func finish() -> (frames:[[Float]],spectrum:[Float]) {
        if bucketCount>0 {flush()}
        return (frames,aggregate.map{$0/Float(max(total,1))})
    }
}
