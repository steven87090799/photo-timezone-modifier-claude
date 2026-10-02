import Foundation

/// Roots are validated and indexed once, not once per photo. Lookup is O(path
/// depth), including jobs containing thousands of explicitly selected files.
final class DestinationPlan {
    let destination: URL
    private let identity: DirectoryIdentity
    private var directories: [String: DirectoryIdentity] = [:]
    private var explicitFiles: Set<String> = []
    private(set) var copiedSidecars: [String: (source: FileIdentity, output: FileIdentity)] = [:]

    init(destination: URL, roots: [URL]) throws {
        try CopyDestination.validate(destination, roots: roots)
        self.destination = destination.standardizedFileURL.resolvingSymlinksInPath()
        identity = try DirectoryIdentity.read(self.destination)
        for root in roots {
            let normalized = root.standardizedFileURL
            if let dir = try? DirectoryIdentity.read(normalized) { directories[normalized.path] = dir }
            else { explicitFiles.insert(normalized.path) }
        }
    }

    func output(for source: URL) throws -> URL {
        try identity.verify(destination)
        let source = source.standardizedFileURL
        var cursor = source.deletingLastPathComponent(), match: URL?
        while true {
            if let identity = directories[cursor.path] {
                try identity.verify(cursor)
                match = cursor
            }
            // Darwin Foundation may append /.. when deleting the last
            // component of a directory URL at root. Stop before that call;
            // comparing parent == cursor alone can loop forever on macOS.
            if cursor.path == "/" { break }
            let parent = cursor.deletingLastPathComponent()
            if cursor.path == parent.path { break }
            cursor = parent
        }
        let output: URL
        if let root = match {
            output = destination.appendingPathComponent(root.lastPathComponent, isDirectory: true)
                .appendingPathComponent(String(source.path.dropFirst(root.path.count + 1)))
        } else {
            guard explicitFiles.contains(source.path) else { throw PhotoError("Photo is outside the inspected source scope.") }
            output = destination.appendingPathComponent(source.lastPathComponent)
        }
        try CopyDestination.prepareOutputParent(output.deletingLastPathComponent(), under: destination)
        try identity.verify(destination)
        return output
    }

    func verify() throws { try identity.verify(destination) }
    func remember(sidecar: URL, sourceIdentity: FileIdentity, output: URL) throws {
        copiedSidecars[sidecar.path + "\0" + output.path] = (sourceIdentity, try FileIdentity.read(output))
    }
    func hasCopied(sidecar: URL, to output: URL) throws -> Bool {
        guard let known = copiedSidecars[sidecar.path + "\0" + output.path] else { return false }
        try known.source.verify(sidecar)
        try known.output.verify(output)
        return true
    }
}

final class SidecarIndex {
    private var directories: [String: [String: [URL]]] = [:]

    private func snapshot(directory: URL, refresh: Bool) throws -> [String: [URL]] {
        let key = directory.standardizedFileURL.path
        if !refresh, let cached = directories[key] { return cached }
        var index: [String: [URL]] = [:]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ["xmp", "on1", "acr"].contains(ext) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            index[url.lastPathComponent.lowercased(), default: []].append(url)
        }
        directories[key] = index
        return index
    }

    func find(beside photo: URL, refresh: Bool = false) throws -> [URL] {
        let directory = photo.deletingLastPathComponent()
        let index = try snapshot(directory: directory, refresh: refresh)
        let stem = photo.deletingPathExtension().lastPathComponent.lowercased()
        let full = photo.lastPathComponent.lowercased()
        var candidates: [URL] = []
        for ext in ["xmp", "on1", "acr"] {
            candidates += index["\(stem).\(ext)"] ?? []
            candidates += index["\(full).\(ext)"] ?? []
        }
        var seenPaths = Set<String>(), seenFiles = Set<String>(), result: [URL] = []
        for url in candidates.sorted(by: { $0.path < $1.path }) {
            guard seenPaths.insert(url.path).inserted else { continue }
            let identity = try FileIdentity.read(url)
            guard seenFiles.insert("\(identity.device):\(identity.inode)").inserted else { continue }
            result.append(url)
        }
        return result
    }

    func verifyUnchanged(_ inspected: [URL], beside photo: URL) throws {
        let current = try find(beside: photo, refresh: true)
        guard Set(current.map(\.path)) == Set(inspected.map(\.path)) else {
            throw PhotoError("Sidecar set changed during processing; photo was not published. Rescan before retrying.")
        }
    }
}

enum SidecarSupport {
    static func verifyUnchanged(_ inspected: [URL], beside photo: URL) throws {
        try SidecarIndex().verifyUnchanged(inspected, beside: photo)
    }

    static func find(beside photo: URL) throws -> [URL] {
        try SidecarIndex().find(beside: photo)
    }
}
