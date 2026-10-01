import Foundation

// Older exported JSONL records remain readable after new diagnostics/state fields.
extension PhotoMetadata {
    enum CodingKeys: String, CodingKey {
        case dateTimeOriginal
        case offsetOriginal
        case offsetDigitized
        case offsetTime
        case fileType
        case createDate
        case modifyDate
        case dateTags
        case make
        case cameraModel
        case cameraSerialNumber
        case lensModel
        case lensModelSource
        case lensInfo
        case compatibilityIssues
        case iso
        case exposureTime
        case aperture
        case focalLength
        case imageWidth
        case imageHeight
        case fileSize
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        dateTimeOriginal = try values.decodeIfPresent(String.self, forKey: .dateTimeOriginal)
        offsetOriginal = try values.decodeIfPresent(String.self, forKey: .offsetOriginal)
        offsetDigitized = try values.decodeIfPresent(String.self, forKey: .offsetDigitized)
        offsetTime = try values.decodeIfPresent(String.self, forKey: .offsetTime)
        fileType = try values.decodeIfPresent(String.self, forKey: .fileType)
        createDate = try values.decodeIfPresent(String.self, forKey: .createDate)
        modifyDate = try values.decodeIfPresent(String.self, forKey: .modifyDate)
        dateTags = try values.decodeIfPresent([String: String].self, forKey: .dateTags) ?? [:]
        make = try values.decodeIfPresent(String.self, forKey: .make)
        cameraModel = try values.decodeIfPresent(String.self, forKey: .cameraModel)
        cameraSerialNumber = try values.decodeIfPresent(String.self, forKey: .cameraSerialNumber)
        lensModel = try values.decodeIfPresent(String.self, forKey: .lensModel)
        lensModelSource = try values.decodeIfPresent(String.self, forKey: .lensModelSource)
        lensInfo = try values.decodeIfPresent(String.self, forKey: .lensInfo)
        compatibilityIssues = try values.decodeIfPresent([String].self, forKey: .compatibilityIssues) ?? []
        iso = try values.decodeIfPresent(String.self, forKey: .iso)
        exposureTime = try values.decodeIfPresent(String.self, forKey: .exposureTime)
        aperture = try values.decodeIfPresent(String.self, forKey: .aperture)
        focalLength = try values.decodeIfPresent(String.self, forKey: .focalLength)
        imageWidth = try values.decodeIfPresent(String.self, forKey: .imageWidth)
        imageHeight = try values.decodeIfPresent(String.self, forKey: .imageHeight)
        fileSize = try values.decodeIfPresent(Int64.self, forKey: .fileSize)
    }
}
extension PhotoItem {
    enum CodingKeys: String, CodingKey {
        case id
        case url
        case status
        case detail
        case metadata
        case outputURL
        case outputMetadata
        case sourceIdentity
        case transactionID
        case publicationUnconfirmed
        case backupURL
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        url = try values.decode(URL.self, forKey: .url)
        status = try values.decode(PhotoStatus.self, forKey: .status)
        detail = try values.decode(String.self, forKey: .detail)
        metadata = try values.decodeIfPresent(PhotoMetadata.self, forKey: .metadata)
        outputURL = try values.decodeIfPresent(URL.self, forKey: .outputURL)
        outputMetadata = try values.decodeIfPresent(PhotoMetadata.self, forKey: .outputMetadata)
        sourceIdentity = try values.decodeIfPresent(FileIdentity.self, forKey: .sourceIdentity)
        transactionID = try values.decodeIfPresent(UUID.self, forKey: .transactionID)
        publicationUnconfirmed = try values.decodeIfPresent(Bool.self, forKey: .publicationUnconfirmed) ?? false
        backupURL = try values.decodeIfPresent(URL.self, forKey: .backupURL)
    }
}
