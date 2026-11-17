import Foundation

final class StopFlag: @unchecked Sendable {
    private let condition=NSCondition()
    private var flag=false,paused=false
    func set(_ value:Bool){condition.lock();flag=value;paused=false;condition.broadcast();condition.unlock()}
    var stopped:Bool {condition.lock();defer{condition.unlock()};return flag}
    var isPaused:Bool {condition.lock();defer{condition.unlock()};return paused}
    func pause(){condition.lock();if !flag {paused=true};condition.broadcast();condition.unlock()}
    func resume(){condition.lock();paused=false;condition.broadcast();condition.unlock()}
    /// Pause blocks on a condition, not a spin loop; stop always wakes paused work.
    func checkpoint()->Bool {
        condition.lock();defer{condition.unlock()}
        while paused && !flag {condition.wait()}
        return !flag
    }
}

/// A bounded pool with dynamic scheduling, ordered output and serialized progress.
/// No operation is queued per song, keeping memory bounded for large libraries.
enum ParallelWork {
    static func run<T>(count: Int, workers: Int, cancelled: @escaping () -> Bool,
                       checkpoint: @escaping () -> Bool = {true},
                       process: @escaping (Int) -> T,
                       completed: @escaping (Int, Int) -> Void) -> [T] {
        guard count > 0 else { return [] }
        let lock = NSLock()
        var next = 0
        var done = 0
        var results = [T?](repeating: nil, count: count)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(1, workers)
        queue.qualityOfService = .utility
        for _ in 0..<min(count, max(1, workers)) {
            queue.addOperation {
                while true {
                    if !checkpoint(){return}
                    lock.lock()
                    if cancelled() || next >= count { lock.unlock(); return }
                    let index = next; next += 1
                    lock.unlock()
                    let result = autoreleasepool { process(index) }
                    lock.lock()
                    results[index] = result
                    done += 1
                    completed(done, index)
                    lock.unlock()
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return results.compactMap { $0 }
    }
}
