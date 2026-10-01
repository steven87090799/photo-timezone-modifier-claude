import Foundation

public enum FileDiscovery {
    public static let extensions: Set<String> = ["arw", "jpg", "jpeg", "tif", "tiff"]

    public static func collect(
        inputs: [URL], recursive: Bool, cancellation: CancellationToken,
        allowDirectories: Bool = true, onPhase: (String) -> Void = { _ in }
    ) -> [PhotoItem] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]
        var items: [PhotoItem] = []
        var seen = Set<String>()
        var fileIdentities = Set<String>()
        var visited = 0

        func add(_ url: URL, status: PhotoStatus = .pending, detail: String = "") {
            let normalized = url.standardizedFileURL
            guard seen.insert(normalized.path).inserted else { return }
            if status == .pending, let identity = try? FileIdentity.read(normalized) {
                guard fileIdentities.insert("\(identity.device):\(identity.inode)").inserted else { return }
            }
            items.append(PhotoItem(url: normalized, status: status, detail: detail))
        }

        func consider(_ url: URL, explicit: Bool) {
            guard !cancellation.isCancelled else { return }
            do {
                let values = try url.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true {
                    if explicit { add(url, status: .skipped, detail: "略過符號連結，請直接選擇原始檔案。") }
                } else if values.isRegularFile == true, url.path.hasSuffix("_original") {
                    let destination = URL(fileURLWithPath: String(url.path.dropLast("_original".count)))
                    if extensions.contains(destination.pathExtension.lowercased()),
                       !manager.fileExists(atPath: destination.path) {
                        add(destination, status: .failed, detail: "原檔遺失，但找到 _original 備份，可使用還原功能。")
                    } else if explicit {
                        add(url, status: .skipped, detail: "請選擇對應的原檔進行還原。")
                    }
                } else if values.isRegularFile == true && extensions.contains(url.pathExtension.lowercased()) {
                    add(url)
                } else if explicit {
                    add(url, status: .skipped, detail: "未支援的檔案；目前支援 ARW、JPEG、TIFF。")
                }
            } catch {
                add(url, status: .failed, detail: "無法存取：\(error.localizedDescription)")
            }
        }

        for input in inputs {
            if cancellation.isCancelled { break }
            guard input.isFileURL else {
                add(input, status: .failed, detail: "只接受本機檔案或已掛載磁碟的檔案。")
                continue
            }
            let input = input.standardizedFileURL
            do {
                let values = try input.resourceValues(forKeys: keys)
                if values.isDirectory == true && values.isSymbolicLink != true {
                    guard allowDirectories else {
                        add(input, status: .failed, detail: "掃描後檔案已變成資料夾；請重新掃描預覽。")
                        continue
                    }
                    if values.isPackage == true {
                        add(input, status: .skipped, detail: "Package directories are not supported.")
                        continue
                    }
                    var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
                    if !recursive { options.insert(.skipsSubdirectoryDescendants) }
                    guard let enumerator = manager.enumerator(
                        at: input, includingPropertiesForKeys: Array(keys), options: options,
                        errorHandler: { url, error in
                            add(url, status: .failed, detail: "無法掃描資料夾：\(error.localizedDescription)")
                            return !cancellation.isCancelled
                        }
                    ) else {
                        add(input, status: .failed, detail: "無法開啟資料夾。")
                        continue
                    }
                    for case let file as URL in enumerator {
                        if cancellation.isCancelled { break }
                        consider(file, explicit: false)
                        visited += 1
                        if visited % 200 == 0 { onPhase("掃描資料夾中，已找到 \(items.count) 個項目…") }
                    }
                } else {
                    consider(input, explicit: true)
                }
            } catch {
                let backup = URL(fileURLWithPath: input.path + "_original")
                if !manager.fileExists(atPath: input.path), extensions.contains(input.pathExtension.lowercased()),
                   (try? FileSafety.ensureRegular(backup)) != nil {
                    add(input, status: .failed, detail: "原檔遺失，但找到 _original 備份，可使用還原功能。")
                } else {
                    add(input, status: .failed, detail: "無法讀取項目：\(error.localizedDescription)")
                }
            }
        }
        return items
    }
}
