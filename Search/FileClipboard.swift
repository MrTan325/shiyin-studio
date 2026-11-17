import AppKit

struct FileClipboardSnapshot {
    let urls: [URL]
    let mode: TransferMode
    let changeCount: Int
}
protocol FilePasteboard {
    var changeCount: Int { get }
    func readURLs() -> [URL]
    func writeURLs(_ urls: [URL]) -> Bool
    func clear()
}
final class SystemFilePasteboard: FilePasteboard {
    let pasteboard: NSPasteboard
    init(_ pasteboard:NSPasteboard) { self.pasteboard = pasteboard }
    var changeCount:Int { pasteboard.changeCount }
    func readURLs() -> [URL] { pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL] ?? [] }
    func writeURLs(_ urls:[URL]) -> Bool { pasteboard.clearContents(); return pasteboard.writeObjects(urls.map { $0 as NSURL }) }
    func clear() { pasteboard.clearContents() }
}

/// A cut is a pending move, never a deletion. An external clipboard write invalidates it.
final class FileClipboard {
    private let backend: FilePasteboard
    private var cutChangeCount: Int?
    init(backend:FilePasteboard) { self.backend = backend }
    convenience init(pasteboard:NSPasteboard = .general) { self.init(backend:SystemFilePasteboard(pasteboard)) }
    @discardableResult func write(_ urls:[URL],mode:TransferMode) -> Bool {
        guard !urls.isEmpty else { return false }
        cutChangeCount = nil
        guard backend.writeURLs(urls) else { return false }
        if mode == .move { cutChangeCount = backend.changeCount }
        return true
    }
    func snapshot() -> FileClipboardSnapshot? {
        let urls = backend.readURLs(); guard !urls.isEmpty else { return nil }
        return FileClipboardSnapshot(urls:urls,mode:cutChangeCount == backend.changeCount ? .move : .copy,changeCount:backend.changeCount)
    }
    func complete(_ report:TransferReport,snapshot:FileClipboardSnapshot) {
        guard snapshot.mode == .move, backend.changeCount == snapshot.changeCount, !report.completed.isEmpty else { return }
        let moved = Set(report.completed.map { canonicalPath($0.source.path) })
        let remaining = snapshot.urls.filter { !moved.contains(canonicalPath($0.path)) }
        if remaining.isEmpty { backend.clear(); cutChangeCount = nil }
        else { write(remaining,mode:.move) }
    }
}
