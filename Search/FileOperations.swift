import Foundation

/// No operation replaces an existing item. Name conflicts are explicit and repeatable.
enum TransferMode: String { case copy, move }
enum ConflictPolicy { case keepBoth, skip }
struct TransferSuccess { let source: URL; let destination: URL }
struct TransferFailure { let source: URL; let message: String }
struct TransferReport {
    var completed = [TransferSuccess]()
    var skipped = [URL]()
    var failures = [TransferFailure]()
}

enum FileOperations {
    /// Rename within the same folder, preserving contents and refusing replacement.
    static func rename(_ source: URL, to name: String) throws -> URL {
        guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains(":"),
              !name.unicodeScalars.contains(where:{ CharacterSet.controlCharacters.contains($0) }) else {
            throw operationError("文件名不能为空，也不能包含 /、: 或控制字符")
        }
        let source = source.standardizedFileURL
        let values = try source.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw operationError("仅支持重命名普通文件")
        }
        if name == source.lastPathComponent { return source }
        let destination = source.deletingLastPathComponent().appendingPathComponent(name)
        // moveItem also rejects a destination created after this check.
        if FileManager.default.fileExists(atPath:destination.path) ||
           (try? FileManager.default.destinationOfSymbolicLink(atPath:destination.path)) != nil {
            throw operationError("已有同名文件，请使用其他名称")
        }
        try FileManager.default.moveItem(at:source,to:destination)
        return destination
    }

    static func transfer(_ sources: [URL], to directory: URL, mode: TransferMode, conflicts: ConflictPolicy,
                         progress: ((Int, Int) -> Void)? = nil) -> TransferReport {
        let manager = FileManager.default
        var report = TransferReport()
        let destinationDirectory = URL(fileURLWithPath:canonicalPath(directory.path),isDirectory:true)
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath:destinationDirectory.path,isDirectory:&isDirectory), isDirectory.boolValue else {
            report.failures = sources.map { TransferFailure(source:$0,message:"目标文件夹不存在或不是目录") }
            return report
        }
        var visited = Set<String>()
        for (index, original) in sources.enumerated() {
            defer { progress?(index + 1, sources.count) }
            // Do not follow the source's final symlink: search results are regular files only.
            let source = original.standardizedFileURL
            let sourcePath = canonicalPath(source.path)
            guard visited.insert(sourcePath).inserted else { report.skipped.append(source); continue }
            do {
                let values = try source.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw operationError("仅支持普通文件；文件夹和符号链接不会被转移")
                }
                let desired = destinationDirectory.appendingPathComponent(source.lastPathComponent)
                if mode == .move && sourcePath == canonicalPath(desired.path) { report.skipped.append(source); continue }
                var destination = desired
                var sequence = 1
                // Retry only file-exists errors. Concurrent creators can never cause an overwrite.
                while true {
                    if manager.fileExists(atPath:destination.path) || (try? manager.destinationOfSymbolicLink(atPath:destination.path)) != nil {
                        if conflicts == .skip { report.skipped.append(source); break }
                        destination = alternateURL(for:desired,number:sequence); sequence += 1
                        continue
                    }
                    do {
                        if mode == .copy { try manager.copyItem(at:source,to:destination) }
                        else { try manager.moveItem(at:source,to:destination) }
                        report.completed.append(TransferSuccess(source:source,destination:destination))
                        break
                    } catch {
                        let ns = error as NSError
                        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteFileExistsError {
                            if conflicts == .skip { report.skipped.append(source); break }
                            destination = alternateURL(for:desired,number:sequence); sequence += 1
                            continue
                        }
                        throw error
                    }
                }
            } catch { report.failures.append(TransferFailure(source:source,message:error.localizedDescription)) }
        }
        return report
    }
    private static func alternateURL(for original: URL, number: Int) -> URL {
        let ext = original.pathExtension
        let stem = ext.isEmpty ? original.lastPathComponent : original.deletingPathExtension().lastPathComponent
        let name = stem + "（副本 \(number)）" + (ext.isEmpty ? "" : "." + ext)
        return original.deletingLastPathComponent().appendingPathComponent(name)
    }
    private static func operationError(_ message:String) -> NSError {
        NSError(domain:"ShiyinFileOperations",code:1,userInfo:[NSLocalizedDescriptionKey:message])
    }
}
