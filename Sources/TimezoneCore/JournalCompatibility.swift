import Foundation

// Older exported JSONL records remain readable after new diagnostics/state fields.
extension PhotoMetadata {
    enum CodingKeys: String, CodingKey {
        case dateTimeOriginal, offsetOriginal, offsetDigitized, offsetTime, fileType, createDate, modifyDate, dateTags
        case make, cameraModel, cameraSerialNumber, bodySerialNumber
        case lensMake, lensModel, lensModelSource, lensInfo, lensSerialNumber
        case compatibilityIssues
        case subSecTimeOriginal, subSecTimeDigitized, subSecTime
        case iso, exposureTime, aperture, exposureProgram, exposureCompensation, meteringMode, flash
        case focalLength, focalLength35mm, whiteBalance, sceneCaptureType
        case orientation, colorSpace, software, mimeType
        case gpsVersionID, gpsLatitude, gpsLatitudeRef, gpsLongitude, gpsLongitudeRef
        case gpsAltitude, gpsAltitudeRef, gpsDateStamp, gpsTimeStamp
        case embeddedEXIFGPSDetected, embeddedXMPGPSDetected, sidecarGPSDetected, gpsSafetyUncertain
        case imageWidth, imageHeight, fileSize
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
        bodySerialNumber = try values.decodeIfPresent(String.self, forKey: .bodySerialNumber)
        lensMake = try values.decodeIfPresent(String.self, forKey: .lensMake)
        lensModel = try values.decodeIfPresent(String.self, forKey: .lensModel)
        lensModelSource = try values.decodeIfPresent(String.self, forKey: .lensModelSource)
        lensInfo = try values.decodeIfPresent(String.self, forKey: .lensInfo)
        lensSerialNumber = try values.decodeIfPresent(String.self, forKey: .lensSerialNumber)
        compatibilityIssues = try values.decodeIfPresent([String].self, forKey: .compatibilityIssues) ?? []

        subSecTimeOriginal = try values.decodeIfPresent(String.self, forKey: .subSecTimeOriginal)
        subSecTimeDigitized = try values.decodeIfPresent(String.self, forKey: .subSecTimeDigitized)
        subSecTime = try values.decodeIfPresent(String.self, forKey: .subSecTime)
        iso = try values.decodeIfPresent(String.self, forKey: .iso)
        exposureTime = try values.decodeIfPresent(String.self, forKey: .exposureTime)
        aperture = try values.decodeIfPresent(String.self, forKey: .aperture)
        exposureProgram = try values.decodeIfPresent(String.self, forKey: .exposureProgram)
        exposureCompensation = try values.decodeIfPresent(String.self, forKey: .exposureCompensation)
        meteringMode = try values.decodeIfPresent(String.self, forKey: .meteringMode)
        flash = try values.decodeIfPresent(String.self, forKey: .flash)
        focalLength = try values.decodeIfPresent(String.self, forKey: .focalLength)
        focalLength35mm = try values.decodeIfPresent(String.self, forKey: .focalLength35mm)
        whiteBalance = try values.decodeIfPresent(String.self, forKey: .whiteBalance)
        sceneCaptureType = try values.decodeIfPresent(String.self, forKey: .sceneCaptureType)

        orientation = try values.decodeIfPresent(String.self, forKey: .orientation)
        colorSpace = try values.decodeIfPresent(String.self, forKey: .colorSpace)
        software = try values.decodeIfPresent(String.self, forKey: .software)
        mimeType = try values.decodeIfPresent(String.self, forKey: .mimeType)
        gpsVersionID = try values.decodeIfPresent(String.self, forKey: .gpsVersionID)
        gpsLatitude = try values.decodeIfPresent(String.self, forKey: .gpsLatitude)
        gpsLatitudeRef = try values.decodeIfPresent(String.self, forKey: .gpsLatitudeRef)
        gpsLongitude = try values.decodeIfPresent(String.self, forKey: .gpsLongitude)
        gpsLongitudeRef = try values.decodeIfPresent(String.self, forKey: .gpsLongitudeRef)
        gpsAltitude = try values.decodeIfPresent(String.self, forKey: .gpsAltitude)
        gpsAltitudeRef = try values.decodeIfPresent(String.self, forKey: .gpsAltitudeRef)
        gpsDateStamp = try values.decodeIfPresent(String.self, forKey: .gpsDateStamp)
        gpsTimeStamp = try values.decodeIfPresent(String.self, forKey: .gpsTimeStamp)
        embeddedEXIFGPSDetected = try values.decodeIfPresent(Bool.self, forKey: .embeddedEXIFGPSDetected) ?? false
        embeddedXMPGPSDetected = try values.decodeIfPresent(Bool.self, forKey: .embeddedXMPGPSDetected) ?? false
        sidecarGPSDetected = try values.decodeIfPresent(Bool.self, forKey: .sidecarGPSDetected) ?? false
        gpsSafetyUncertain = try values.decodeIfPresent(Bool.self, forKey: .gpsSafetyUncertain) ?? false

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
