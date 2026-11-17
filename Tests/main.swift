import Foundation
import AppKit
import AVFoundation
import CoreVideo

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n",stderr); exit(1) }
    checks += 1; print("PASS: \(message)")
}
let temp = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("MediaSearch-tests-" + UUID().uuidString)
try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:temp) }
let db = try Database(url:temp.appendingPathComponent("index.sqlite"))
func record(_ name:String,root:String = "/Music") -> FileRecord {
    let ext = URL(fileURLWithPath:name).pathExtension.lowercased()
    return FileRecord(path:root+"/"+name,name:name,ext:ext,kind:fileKind(ext),size:1000,modified:1)
}
let fixtures = [record("DJ 夜曲 Remix 128.mp3"),record("DJ 蓝色海洋.wav"),record("A_100% Mix.mp3"),record("Café Live.mp4"),record("O\"Brien's Mix.flac"),record("计划.txt"),record("Remix Premiere.mov",root:"/Video")]
db.upsert(fixtures,root:"/Music",generation:"1")
check(db.hasTrigrams,"SQLite trigram index is available")
check(db.search("夜曲").total == 1,"two-character Chinese search")
check(db.search("蓝色海洋").total == 1,"Chinese trigram search")
check(db.search("DJ remix").total == 1,"case-insensitive AND keyword search")
check(db.search("cafe").total == 1,"accent folding")
check(db.search("100%").total == 1 && db.search("_").total == 1,"percent and underscore are literal")
check(db.search("O\"Brien").total == 1,"quotes and apostrophes are literal")
check(db.search("' OR 1=1 --").total == 0,"query cannot inject SQL")
check(db.search("",kind:"audio").total == 4,"audio category filter")
check(db.search("夜曲",kind:"video").total == 0,"combined category filter")
check(db.search("正文中才有的词").total == 0,"document content is not indexed")
let changed = FileRecord(path:fixtures[0].path,name:"Renamed.mp3",ext:"mp3",kind:"audio",size:1000,modified:2)
db.upsert([changed],root:"/Music",generation:"2")
check(db.search("夜曲").total == 0 && db.search("Renamed").total == 1,"trigram update removes old name")
var media = MediaInfo(); media.bpm = "128"; media.key = "8A"; media.duration = 125; media.bitrate = 320000
db.updateMedia(path:changed.path,modified:2,size:1000,info:media)
let result = db.search("Renamed").files[0]
check(result.bpm == "128" && result.key == "8A" && result.durationText == "2:05","media cache and display formatting")
db.updateMedia(path:changed.path,modified:1,size:1000,info:MediaInfo())
check(db.search("Renamed").files[0].bpm == "128","outdated metadata cannot overwrite a changed file")
db.remove(path:"/Music/A_100% Mix.mp3")
check(db.search("100%").total == 0,"deleted file removed from both indexes")
db.upsert([record("Sub.mp3",root:"/Music/nested")],root:"/Music",generation:"3")
db.remove(path:"/Music/nested")
check(db.search("Sub.mp3").total == 0,"directory deletion removes descendants")
let bulk = (0..<100000).map { record(String(format:"Library track %06d soundtrack.mp3",$0),root:"/Benchmark") }
let start = Date()
for offset in stride(from:0,to:bulk.count,by:300) { db.upsert(Array(bulk[offset..<min(offset+300,bulk.count)]),root:"/Benchmark",generation:"bench") }
print(String(format:"BENCH index 100000 records: %.2f s",Date().timeIntervalSince(start)))
for query in ["087654","track soundtrack","夜曲","mp3","zzzznomatch","DJ"] {
    let found = db.search(query)
    print(String(format:"BENCH query %@: %d matches, %.2f ms",query,found.total,found.elapsed*1000))
}
check(db.search("087654").total == 1,"100k-record search correctness")
check(db.search("track").files.count == 2000 && db.search("track").total == 100000,"result limit preserves total match count")
check(db.search("",root:"/Benchmark").total == 100000,"root filter")
db.finishScan(root:"/Benchmark",subtree:"/Benchmark",generation:"new")
check(db.search("",root:"/Benchmark").total == 0,"scan reconciliation deletes stale entries")

// Tag fixtures exercise ID3v2.3, ID3v2.4 and FLAC Vorbis comments.
func frame(_ key:String,_ value:String,version:UInt8) -> [UInt8] {
    let content = [UInt8(3)] + Array(value.utf8); let n = content.count
    let size = version == 4 ? [UInt8((n >> 21)&127),UInt8((n >> 14)&127),UInt8((n >> 7)&127),UInt8(n&127)] : [UInt8((n >> 24)&255),UInt8((n >> 16)&255),UInt8((n >> 8)&255),UInt8(n&255)]
    return Array(key.utf8) + size + [0,0] + content
}
for version:UInt8 in [3,4] {
    let body = frame("TBPM","128",version:version) + frame("TKEY","Am",version:version) + frame("TXXX","INITIALKEY\0"+"8A",version:version)
    let n = body.count
    let data = Data(Array("ID3".utf8) + [version,0,0,UInt8((n>>21)&127),UInt8((n>>14)&127),UInt8((n>>7)&127),UInt8(n&127)] + body)
    let url = temp.appendingPathComponent("tags\(version).mp3"); try data.write(to:url)
    let tags = MediaReader.readTags(url)
    check(tags["TBPM"] == "128" && tags["TKEY"] == "Am" && tags["INITIALKEY"] == "8A","ID3v2.\(version) BPM, key, custom DJ key")
}
func le(_ x:Int) -> [UInt8] { [UInt8(x&255),UInt8((x>>8)&255),UInt8((x>>16)&255),UInt8((x>>24)&255)] }
let comments = ["BPM=126.5","INITIALKEY=F#m"]
var block = le(4) + Array("test".utf8) + le(comments.count)
for comment in comments { block += le(comment.utf8.count) + Array(comment.utf8) }
let flac = temp.appendingPathComponent("tags.flac")
try Data(Array("fLaC".utf8) + [132,UInt8((block.count>>16)&255),UInt8((block.count>>8)&255),UInt8(block.count&255)] + block).write(to:flac)
check(MediaReader.readTags(flac)["INITIALKEY"] == "F#m" && MediaReader.readTags(flac)["BPM"] == "126.5","FLAC Vorbis BPM and key")
let malformed = temp.appendingPathComponent("bad.mp3"); try Data([73,68,51,4,0,0,127,127,127,127,255,255]).write(to:malformed)
check(MediaReader.readTags(malformed).isEmpty,"malformed tags are bounded and safe")

// Generate PCM WAV, then read real AVFoundation duration and bitrate.
let wav = temp.appendingPathComponent("tone.wav")
let format = AVAudioFormat(standardFormatWithSampleRate:44100,channels:2)!
let audio = try AVAudioFile(forWriting:wav,settings:format.settings)
let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:88200)!
buffer.frameLength = 88200
for c in 0..<2 { for i in 0..<88200 { buffer.floatChannelData![c][i] = Float(sin(Double(i)*2*Double.pi*440/44100))*0.1 } }
try audio.write(from:buffer)
// AVAudioFile flushes on deinitialisation; use a separate scoped writer below.
let waveURL = temp.appendingPathComponent("fixture.wav")
func writeWave() throws { let out = try AVAudioFile(forWriting:waveURL,settings:format.settings); try out.write(from:buffer) }
try writeWave()
// Read a deterministic 24-fps raw QuickTime fixture built without external codecs.
let videoURL = URL(fileURLWithPath:CommandLine.arguments[1])

// Exercise scanner reconciliation against a real temporary directory.
let scanRoot = temp.appendingPathComponent("scan")
try FileManager.default.createDirectory(at:scanRoot.appendingPathComponent("nested"),withIntermediateDirectories:true)
try Data("OnlyTheContentsToken".utf8).write(to:scanRoot.appendingPathComponent("nested/文稿.txt"))
let scanDB = try Database(url:temp.appendingPathComponent("scan.sqlite"))
let indexer = Indexer(db:scanDB,excluded:temp.appendingPathComponent("excluded").path)
func awaitCondition(_ body:() -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline { if body() { return true }; RunLoop.current.run(until:Date().addingTimeInterval(0.03)) }
    return body()
}
indexer.configure([scanRoot.path,scanRoot.appendingPathComponent("nested").path])
check(awaitCondition { scanDB.search("文稿").total == 1 },"real recursive scanner with overlapping roots")
check(scanDB.search("OnlyTheContentsToken").total == 0,"real document body never enters index")
try FileManager.default.moveItem(at:scanRoot.appendingPathComponent("nested/文稿.txt"),to:scanRoot.appendingPathComponent("renamed.txt"))
indexer.rescan()
let renamedOK = awaitCondition { scanDB.search("renamed").total == 1 && scanDB.search("文稿").total == 0 }
if !renamedOK { print("DEBUG root \(scanRoot.path) rows \(scanDB.search("").files.map { ($0.name,$0.path) })") }
check(renamedOK,"real file rename and stale cleanup")
try FileManager.default.removeItem(at:scanRoot.appendingPathComponent("renamed.txt"))
indexer.rescan()
check(awaitCondition { scanDB.search("").total == 0 },"real file deletion reconciliation")
indexer.configure([])
// File operations only touch this run's private temporary fixture directory.
let transfers = temp.appendingPathComponent("transfers")
let fromA = transfers.appendingPathComponent("A")
let fromB = transfers.appendingPathComponent("B")
let to = transfers.appendingPathComponent("to")
for directory in [fromA,fromB,to] { try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true) }
func put(_ name:String,_ text:String,in directory:URL) throws -> URL {
    let url = directory.appendingPathComponent(name); try Data(text.utf8).write(to:url); return url
}
func contents(_ url:URL) -> String { (try? String(contentsOf:url,encoding:.utf8)) ?? "" }
func exists(_ url:URL) -> Bool { FileManager.default.fileExists(atPath:url.path) }
let song = try put("歌曲.mp3","original audio bytes",in:fromA)
let copied = FileOperations.transfer([song],to:to,mode:.copy,conflicts:.keepBoth)
check(copied.completed.count == 1 && exists(song) && contents(to.appendingPathComponent("歌曲.mp3")) == "original audio bytes","file copy preserves source and bytes")
let duplicate = FileOperations.transfer([song],to:to,mode:.copy,conflicts:.keepBoth)
check(duplicate.completed.count == 1 && duplicate.completed[0].destination.lastPathComponent == "歌曲（副本 1）.mp3" && contents(to.appendingPathComponent("歌曲.mp3")) == "original audio bytes","keep-both renames Unicode filename without overwriting")
let duplicate2 = FileOperations.transfer([song],to:to,mode:.copy,conflicts:.keepBoth)
check(duplicate2.completed.first?.destination.lastPathComponent == "歌曲（副本 2）.mp3","keep-both finds next unused filename")
let skipped = FileOperations.transfer([song],to:to,mode:.move,conflicts:.skip)
check(skipped.skipped.count == 1 && skipped.completed.isEmpty && exists(song),"skip conflict keeps original source")
let move = try put("move.wav","pcm",in:fromA)
let moved = FileOperations.transfer([move],to:to,mode:.move,conflicts:.keepBoth)
check(moved.completed.count == 1 && !exists(move) && contents(to.appendingPathComponent("move.wav")) == "pcm","move transfers bytes and removes source only on success")
let stationary = FileOperations.transfer([to.appendingPathComponent("move.wav")],to:to,mode:.move,conflicts:.keepBoth)
check(stationary.skipped.count == 1 && exists(to.appendingPathComponent("move.wav")),"moving to source directory is a safe no-op")
let copyInPlace = FileOperations.transfer([song],to:fromA,mode:.copy,conflicts:.keepBoth)
check(copyInPlace.completed.first?.destination.lastPathComponent == "歌曲（副本 1）.mp3" && exists(song),"copy within source directory creates a duplicate")
let fileA = try put("same.mp4","A-video",in:fromA)
let fileB = try put("same.mp4","B-video",in:fromB)
let batch = FileOperations.transfer([fileA,fileB],to:to,mode:.copy,conflicts:.keepBoth)
check(batch.completed.count == 2 && Set(batch.completed.map { contents($0.destination) }) == ["A-video","B-video"],"same-name files from multiple directories preserve both contents")
let missing = fromA.appendingPathComponent("missing.mp3")
let partial = FileOperations.transfer([missing,song],to:to,mode:.copy,conflicts:.keepBoth)
check(partial.failures.count == 1 && partial.completed.count == 1 && exists(song),"batch failure is reported while other items continue")
let invalid = FileOperations.transfer([song],to:to.appendingPathComponent("no-directory"),mode:.move,conflicts:.keepBoth)
check(invalid.failures.count == 1 && exists(song),"invalid target never removes source")
let fileTarget = FileOperations.transfer([song],to:to.appendingPathComponent("歌曲.mp3"),mode:.move,conflicts:.keepBoth)
check(fileTarget.failures.count == 1 && exists(song),"file cannot be used as target directory")
let directorySource = FileOperations.transfer([fromB],to:to,mode:.move,conflicts:.keepBoth)
check(directorySource.failures.count == 1 && exists(fromB),"directory sources are rejected")
let link = fromA.appendingPathComponent("link.mp3")
try FileManager.default.createSymbolicLink(at:link,withDestinationURL:song)
let linked = FileOperations.transfer([link],to:to,mode:.move,conflicts:.keepBoth)
check(linked.failures.count == 1 && exists(link) && exists(song),"source symlinks cannot unexpectedly move their targets")
let dangling = to.appendingPathComponent("dangling.wav")
try FileManager.default.createSymbolicLink(at:dangling,withDestinationURL:fromA.appendingPathComponent("absent"))
let danglingSource = try put("dangling.wav","sound",in:fromA)
let danglingCopy = FileOperations.transfer([danglingSource],to:to,mode:.copy,conflicts:.keepBoth)
check(danglingCopy.completed.first?.destination.lastPathComponent == "dangling（副本 1）.wav" && (try? FileManager.default.destinationOfSymbolicLink(atPath:dangling.path)) != nil,"dangling destination symlink is not overwritten")
let repeated = FileOperations.transfer([song,song],to:to,mode:.copy,conflicts:.keepBoth)
check(repeated.completed.count == 1 && repeated.skipped.count == 1,"duplicate source selection transfers only once")
var progressCounts = [Int]()
_ = FileOperations.transfer([missing,song],to:to,mode:.copy,conflicts:.skip) { done,_ in progressCounts.append(done) }
check(progressCounts == [1,2],"progress accounts for failures and skipped files")

// Rename real temporary files; invalid input and collisions must preserve originals.
let renameSource = try put("重命名前.mp3","rename audio bytes",in:fromA)
let renameDestination = try FileOperations.rename(renameSource,to:"重命名后.mp3")
check(!exists(renameSource) && contents(renameDestination) == "rename audio bytes","rename preserves bytes and changes Unicode filename")
let unchangedRename = try FileOperations.rename(renameDestination,to:"重命名后.mp3")
check(unchangedRename == renameDestination,"unchanged rename is a safe no-op")
func renameFails(_ source:URL,_ name:String) -> Bool {
    do { _ = try FileOperations.rename(source,to:name); return false } catch { return true }
}
for name in ["", "   ", ".", "..", "../escape.mp3", "folder/file.mp3", "bad:name.mp3", "bad\nname.mp3", "bad\0name.mp3"] {
    check(renameFails(renameDestination,name) && contents(renameDestination) == "rename audio bytes","invalid rename rejected: \(String(reflecting:name))")
}
let occupiedRename = try put("occupied.mp3","keep existing",in:fromA)
check(renameFails(renameDestination,"occupied.mp3") && contents(occupiedRename) == "keep existing" && exists(renameDestination),"rename conflict preserves both files")
let renameLink = fromA.appendingPathComponent("rename-link.mp3")
try FileManager.default.createSymbolicLink(at:renameLink,withDestinationURL:missing)
check(renameFails(renameDestination,"rename-link.mp3") && exists(renameDestination) && (try? FileManager.default.destinationOfSymbolicLink(atPath:renameLink.path)) != nil,"rename cannot replace dangling symlink")
check(renameFails(link,"renamed-link.mp3") && exists(song),"rename rejects symlink source without changing target")
check(renameFails(fromB,"renamed-folder") && exists(fromB),"rename rejects directory source")
check(renameFails(missing,"missing-renamed.mp3"),"missing rename source reports failure")
let newExtension = try FileOperations.rename(renameDestination,to:"重命名后.wav")
check(contents(newExtension) == "rename audio bytes" && !exists(renameDestination),"explicit extension rename preserves bytes")

final class MemoryFilePasteboard:FilePasteboard {
    var changeCount = 0
    var urls = [URL]()
    func readURLs() -> [URL] { urls }
    func writeURLs(_ urls:[URL]) -> Bool { changeCount += 1; self.urls = urls; return true }
    func clear() { changeCount += 1; urls = [] }
}
let memoryBoard = MemoryFilePasteboard()
let clipboard = FileClipboard(backend:memoryBoard)
check(clipboard.write([song],mode:.copy) && clipboard.snapshot()?.mode == .copy,"copy clipboard state")
check(clipboard.write([song,fileA],mode:.move) && clipboard.snapshot()?.mode == .move && exists(song),"cut stages files without moving or deleting them")
let cutState = clipboard.snapshot()!
var partialMove = TransferReport()
partialMove.completed.append(TransferSuccess(source:song,destination:to.appendingPathComponent("歌曲.mp3")))
clipboard.complete(partialMove,snapshot:cutState)
check(clipboard.snapshot()?.urls.count == 1 && clipboard.snapshot()?.urls.first?.lastPathComponent == "same.mp4" && clipboard.snapshot()?.mode == .move,"partial cut success keeps unresolved items staged")
let remaining = clipboard.snapshot()!
clipboard.complete(TransferReport(),snapshot:remaining)
check(clipboard.snapshot()?.changeCount == remaining.changeCount,"cancelled or failed transfer preserves pending cut")
var finalMove = TransferReport(); finalMove.completed.append(TransferSuccess(source:fileA,destination:to.appendingPathComponent("same.mp4")))
clipboard.complete(finalMove,snapshot:remaining)
check(clipboard.snapshot() == nil,"successful cut paste consumes move clipboard")
clipboard.write([song],mode:.move)
let old = clipboard.snapshot()!
_ = memoryBoard.writeURLs([fileB])
check(clipboard.snapshot()?.mode == .copy,"external clipboard update invalidates pending cut")
clipboard.complete(partialMove,snapshot:old)
check(clipboard.snapshot()?.urls.first?.path == fileB.path,"transfer completion cannot erase a newer clipboard")
clipboard.write([song],mode:.copy)
let copySnapshot = clipboard.snapshot()!
clipboard.complete(partialMove,snapshot:copySnapshot)
check(clipboard.snapshot()?.changeCount == copySnapshot.changeCount,"copy paste can be repeated without consuming clipboard")

// Probe the real adapter separately; the isolated execution environment may lack pasteboard services.
let nativeBoard = NSPasteboard.withUniqueName()
defer { nativeBoard.releaseGlobally() }
let nativeClipboard = FileClipboard(pasteboard:nativeBoard)
if nativeClipboard.write([song],mode:.copy) {
    check(nativeClipboard.snapshot()?.urls.first?.lastPathComponent == "歌曲.mp3","native file URL clipboard roundtrip")
    check(nativeClipboard.write([song],mode:.move) && nativeClipboard.snapshot()?.mode == .move,"native cut clipboard state")
} else { print("SKIP: native pasteboard service unavailable in this execution environment") }

let done = DispatchSemaphore(value:0)
Task {
    var file = record("fixture.wav"); file.path = waveURL.path; file.size = Int64((try? waveURL.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)
    let info = await MediaReader.read(file)
    check(abs(info.duration - 2) < 0.05,"real WAV duration")
    check(info.bitrate > 1000000,"real WAV bitrate")
    check(info.bpm.isEmpty && info.key.isEmpty,"missing BPM/key never fabricated")
    var videoFile = record("fixture.mov"); videoFile.path = videoURL.path
    let video = await MediaReader.read(videoFile)
    check(video.resolution == "320 × 180","real video resolution")
    check(abs(video.fps - 24) < 0.1,"real video FPS")
    check(video.duration > 0.9 && video.duration < 1.1,"real video duration")
    check(video.bitrate > 0,"real video bitrate")
    print("ALL \(checks) CHECKS PASSED")
    done.signal()
}
guard done.wait(timeout:.now()+30) == .success else { fatalError("Media test timed out") }
