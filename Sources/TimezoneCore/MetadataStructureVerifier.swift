import Foundation

/// ExifTool's extended structural diagnostics supplement readable-tag and
/// payload checks. This is not a certification of undocumented maker formats.
enum MetadataStructureVerifier {
    @discardableResult
    static func verify(source: URL, candidate: URL, tool: ExifTool,
                       cancellation: CancellationToken? = nil) throws -> [String] {
        let originalIdentity = try FileIdentity.read(source)
        let candidateIdentity = try FileIdentity.read(candidate)
        let original = try diagnostics(source, tool: tool, cancellation: cancellation)
        let output = try diagnostics(candidate, tool: tool, cancellation: cancellation)
        try originalIdentity.verify(source)
        try candidateIdentity.verify(candidate)
        let added = output.filter { key, count in count > original[key, default: 0] }.keys.sorted()
        guard added.isEmpty else {
            throw PhotoError("寫入後出現新的 EXIF／容器結構問題，未接受此輸出：\(added.joined(separator: "；"))")
        }
        return original.keys.sorted()
    }

    private static func diagnostics(_ file: URL, tool: ExifTool,
                                    cancellation: CancellationToken?) throws -> [String: Int] {
        let result = try tool.execute(["-j", "-a", "-G1:4", "-s", "-n", "-validate", "-warning", "-error", file.path],
                                      timeout: 120, cancellation: cancellation)
        guard result.status == 0,
              let rows = try JSONSerialization.jsonObject(with: result.stdout) as? [[String: Any]],
              rows.count == 1, let row = rows.first,
              row.keys.contains(where: { MetadataVerifier.canonicalCopyKey($0) == "ExifTool:Validate" }) else {
            throw PhotoError("EXIF／容器結構診斷未能完成，未接受此輸出。\(result.text)")
        }
        var warnings: [String: Int] = [:]
        for (key, raw) in row {
            let canonical = MetadataVerifier.canonicalCopyKey(key)
            if canonical == "ExifTool:Error" {
                throw PhotoError("EXIF／容器結構錯誤，未接受此輸出：\(raw)")
            }
            if canonical == "ExifTool:Warning", let warning = raw as? String {
                warnings[warning, default: 0] += 1
            }
        }
        if !result.stderr.isEmpty { warnings[result.stderr, default: 0] += 1 }
        return warnings
    }
}
