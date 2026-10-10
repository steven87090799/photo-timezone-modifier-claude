import Foundation

enum BuildIdentity {
    static let description: String = {
        guard let url = Bundle.main.url(forResource: "BuildIdentity", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let revision = values["revision"] as? String else { return "開發執行檔（未封裝建置資訊）" }
        return "\(revision.prefix(12))\((values["dirty"] as? Bool == true) ? "＋未提交修改" : "") · CI \(values["run"] as? String ?? "local")"
    }()
}
