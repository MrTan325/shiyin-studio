import Foundation

enum CompareBackend {case cpu,gpu,cache}
struct ComparisonJob {let pair:AudioPair;let bytes:Int}

/// One bounded shared queue. GPU takes batches; CPU lanes take disjoint single jobs.
/// A GPU failure returns its entire uncommitted batch before disabling that lane.
final class ComparisonPipeline:@unchecked Sendable {
    private let condition=NSCondition()
    private let group=DispatchGroup()
    private var queue=[ComparisonJob](),head=0,queuedBytes=0
    private var closed=false,gpuEnabled:Bool,gpuWaiting:Bool,gpuAlive:Bool
    private let hybrid:Bool
    private let cancelled:()->Bool
    private let checkpoint:()->Bool
    private let cpu:(AudioPair)->PairScore?
    private let gpu:([AudioPair])throws->[PairScore]
    private let complete:([AudioPair],[PairScore],CompareBackend)->Void
    private let failure:(String)->Void
    private let maxPairs:Int,maxBytes=32*1024*1024
    private let gpuBatchPairs:Int,gpuBatchBytes:Int
    private(set) var peakQueuedPairs=0
    private(set) var peakQueuedBytes=0
    init(workers:Int,useGPU:Bool,hybrid:Bool,gpuBatchPairs:Int=128,gpuBatchBytes:Int=8*1024*1024,cancelled:@escaping ()->Bool,checkpoint:@escaping ()->Bool = {true},
         cpu:@escaping(AudioPair)->PairScore?,gpu:@escaping([AudioPair])throws->[PairScore],
         complete:@escaping([AudioPair],[PairScore],CompareBackend)->Void,failure:@escaping(String)->Void) {
        self.gpuBatchPairs=max(1,min(1024,gpuBatchPairs));self.gpuBatchBytes=max(1,min(32*1024*1024,gpuBatchBytes))
        self.maxPairs=max(512,self.gpuBatchPairs*2)
        self.gpuEnabled=useGPU;self.gpuWaiting=useGPU;self.gpuAlive=useGPU;self.hybrid=hybrid;self.cancelled=cancelled
        self.checkpoint=checkpoint;self.cpu=cpu;self.gpu=gpu;self.complete=complete;self.failure=failure
        if useGPU {
            group.enter()
            DispatchQueue.global(qos:.utility).async {
                defer{self.group.leave()}
                while self.checkpoint(),let jobs=self.takeGPU() {
                    do {
                        let pairs=jobs.map{$0.pair}
                        let scores=try autoreleasepool{try self.gpu(pairs)}
                        guard scores.count==pairs.count else{throw AudioError.message("GPU 返回数量不完整")}
                        self.complete(pairs,scores,.gpu)
                    } catch is CancellationError {
                        self.returnToCPU([]);return
                    } catch {
                        self.failure("【GPU 回退】\(error.localizedDescription)")
                        self.returnToCPU(jobs);return
                    }
                }
            }
        }
        for _ in 0..<max(1,workers) {
            group.enter()
            DispatchQueue.global(qos:.utility).async {
                defer{self.group.leave()}
                // Small completion batches reduce SQLite lock/transaction overhead.
                var pairs=[AudioPair](),scores=[PairScore]()
                func flush(){if !pairs.isEmpty {self.complete(pairs,scores,.cpu);pairs=[];scores=[]}}
                while self.checkpoint(),let job=self.takeCPU() {
                    let score:PairScore?=autoreleasepool{self.cpu(job.pair)}
                    if let score=score {pairs.append(job.pair);scores.append(score)}
                    if pairs.count>=8 {flush()}
                }
                flush()
            }
        }
    }
    func submit(_ jobs:[ComparisonJob]) {
        guard checkpoint() else{return}
        condition.lock();defer{condition.unlock()}
        for job in jobs {
            while !cancelled() && !closed && head<queue.count && (queue.count-head>=maxPairs || queuedBytes+job.bytes>maxBytes) {
                condition.broadcast();condition.wait(until:Date().addingTimeInterval(0.05))
            }
            if cancelled() || closed {condition.broadcast();return}
            queue.append(job);queuedBytes+=job.bytes
            peakQueuedPairs=max(peakQueuedPairs,queue.count-head);peakQueuedBytes=max(peakQueuedBytes,queuedBytes)
        }
        condition.broadcast()
    }
    private func takeGPU()->[ComparisonJob]? {
        condition.lock();defer{condition.unlock()}
        gpuWaiting=true;condition.broadcast()
        while head==queue.count && !closed && !cancelled() {condition.wait(until:Date().addingTimeInterval(0.05))}
        if cancelled() || head==queue.count {gpuWaiting=false;gpuEnabled=false;gpuAlive=false;condition.broadcast();return nil}
        var jobs=[ComparisonJob](),bytes=0
        while head<queue.count && jobs.count<gpuBatchPairs {
            let next=queue[head]
            if !jobs.isEmpty && bytes+next.bytes>gpuBatchBytes {break}
            jobs.append(next);head+=1;bytes+=next.bytes;queuedBytes-=next.bytes
        }
        gpuWaiting=false;compact();condition.broadcast();return jobs
    }
    private func takeCPU()->ComparisonJob? {
        condition.lock();defer{condition.unlock()}
        while !cancelled() {
            if head<queue.count && (!gpuEnabled || (hybrid && !gpuWaiting)) {
                let job=queue[head];head+=1;queuedBytes-=job.bytes;compact();condition.broadcast();return job
            }
            if closed && head==queue.count && !gpuAlive {return nil}
            condition.wait(until:Date().addingTimeInterval(0.05))
        }
        return nil
    }
    private func compact(){if head>=128 {queue.removeFirst(head);head=0}}
    private func returnToCPU(_ jobs:[ComparisonJob]) {
        condition.lock();defer{condition.unlock()}
        if !cancelled() {
            // This one failed batch can temporarily exceed the queue's normal budget.
            queue=jobs+Array(queue[head...]);head=0;queuedBytes+=jobs.reduce(0){$0+$1.bytes}
        }
        gpuEnabled=false;gpuWaiting=false;gpuAlive=false;condition.broadcast()
    }
    func finish(){condition.lock();closed=true;condition.broadcast();condition.unlock();group.wait()}
}

/// Result merging is serialized; compute lanes and producer never mutate UI state.
final class ComparisonResults:@unchecked Sendable {
    private let lock=NSLock()
    private var matches=[Match]()
    private var cpu=0,gpu=0,cached=0
    private let songs:[SongPrint]
    init(_ songs:[SongPrint]){self.songs=songs}
    func add(_ pairs:[AudioPair],scores:[PairScore],backend:CompareBackend) {
        lock.lock();defer{lock.unlock()}
        switch backend {case .cpu:cpu+=scores.count;case .gpu:gpu+=scores.count;case .cache:cached+=scores.count}
        for(pair,score) in zip(pairs,scores) where score.score>=0.72 {matches.append(Match(first:songs[pair.first],second:songs[pair.second],score:score.score,offset:score.offset))}
    }
    func counts()->(cpu:Int,gpu:Int,cached:Int){lock.lock();defer{lock.unlock()};return(cpu,gpu,cached)}
    func snapshot()->(matches:[Match],cpu:Int,gpu:Int,cached:Int) {lock.lock();defer{lock.unlock()};return(matches,cpu,gpu,cached)}
}
