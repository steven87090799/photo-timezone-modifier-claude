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

enum SidecarSupport {
    static func find(beside photo: URL) throws -> [URL] {
        let stem = photo.deletingPathExtension(), fm = FileManager.default
        var seen = Set<String>(), seenFiles = Set<String>(), result: [URL] = []
        for ext in ["xmp", "XMP", "on1", "ON1", "acr", "ACR"] {
            for base in [stem, photo] {
                let url = base.appendingPathExtension(ext)
                guard seen.insert(url.path).inserted, fm.fileExists(atPath: url.path) else { continue }
                let identity = try FileIdentity.read(url)
                guard seenFiles.insert("\(identity.device):\(identity.inode)").inserted else { continue }
                result.append(url)
            }
        }
        return result
    }
}
