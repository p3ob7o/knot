import CryptoKit
import Foundation
import ImageIO

public enum AssetStagingError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case tooLarge
    case unsupportedType
    case declaredTypeMismatch
    case tooManyPixels
    case totalDraftLimit
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .empty: "The image is empty."
        case .tooLarge: "Images are limited to 25 MiB each."
        case .unsupportedType: "Use a PNG, JPEG, GIF, WebP, or HEIC image."
        case .declaredTypeMismatch: "The file contents do not match the declared image type."
        case .tooManyPixels: "Images are limited to 40 megapixels."
        case .totalDraftLimit: "A draft may stage at most 100 MiB of images."
        case .writeFailed: "The image could not be stored locally."
        }
    }
}

public actor AssetStager {
    public static let maximumAssetBytes = 25 * 1_024 * 1_024
    public static let maximumDraftBytes = 100 * 1_024 * 1_024
    public static let maximumImageCount = 50
    public static let maximumPixels = 40_000_000

    private let rootDirectory: URL
    private let store: CaptureStore

    public init(rootDirectory: URL, store: CaptureStore) {
        self.rootDirectory = rootDirectory
        self.store = store
    }

    public func stage(
        data: Data,
        originalName: String,
        declaredMediaType: String,
        draftID: DraftID
    ) async throws -> AssetMetadata {
        guard !data.isEmpty else { throw AssetStagingError.empty }
        guard data.count <= Self.maximumAssetBytes else { throw AssetStagingError.tooLarge }
        let detected = try Self.detectedType(data)
        guard Self.mediaType(declaredMediaType, matches: detected.mediaType) else {
            throw AssetStagingError.declaredTypeMismatch
        }
        if let width = detected.width, let height = detected.height {
            guard width > 0, height > 0, width <= Self.maximumPixels / max(1, height) else {
                throw AssetStagingError.tooManyPixels
            }
        }
        let current = try await store.draftAssetUsage(draftID: draftID)
        guard current.count < Self.maximumImageCount,
              current.bytes + data.count <= Self.maximumDraftBytes else {
            throw AssetStagingError.totalDraftLimit
        }

        let id = AssetID()
        let relative = "assets/\(id.description)/original"
        let directory = rootDirectory.appending(path: "assets/\(id.description)", directoryHint: .isDirectory)
        let target = directory.appending(path: "original")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: target, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            let metadata = AssetMetadata(
                id: id,
                localRelativePath: relative,
                originalName: originalName,
                mediaType: detected.mediaType,
                byteCount: data.count,
                sha256: Self.sha256(data),
                width: detected.width,
                height: detected.height
            )
            try await store.registerAsset(metadata)
            try await store.linkDraftAsset(draftID: draftID, assetID: id)
            return metadata
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if error is CaptureStoreError { throw error }
            throw AssetStagingError.writeFailed
        }
    }

    public func stage(
        fileURL: URL,
        originalName: String,
        declaredMediaType: String,
        draftID: DraftID
    ) async throws -> AssetMetadata {
        let values = try fileURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw AssetStagingError.unsupportedType
        }
        guard let declaredBytes = values.fileSize, declaredBytes > 0 else {
            throw AssetStagingError.empty
        }
        guard declaredBytes <= Self.maximumAssetBytes else { throw AssetStagingError.tooLarge }
        let current = try await store.draftAssetUsage(draftID: draftID)
        guard current.count < Self.maximumImageCount,
              current.bytes + declaredBytes <= Self.maximumDraftBytes else {
            throw AssetStagingError.totalDraftLimit
        }

        let id = AssetID()
        let relative = "assets/" + id.description + "/original"
        let directory = rootDirectory
            .appending(path: "assets/" + id.description, directoryHint: .isDirectory)
        let target = directory.appending(path: "original")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard FileManager.default.createFile(
                atPath: target.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else { throw AssetStagingError.writeFailed }

            let input = try FileHandle(forReadingFrom: fileURL)
            let output = try FileHandle(forWritingTo: target)
            defer {
                try? input.close()
                try? output.close()
            }
            var hasher = SHA256()
            var copiedBytes = 0
            while let chunk = try input.read(upToCount: 256 * 1_024), !chunk.isEmpty {
                copiedBytes += chunk.count
                guard copiedBytes <= Self.maximumAssetBytes else {
                    throw AssetStagingError.tooLarge
                }
                guard current.bytes + copiedBytes <= Self.maximumDraftBytes else {
                    throw AssetStagingError.totalDraftLimit
                }
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
            }
            guard copiedBytes == declaredBytes else { throw AssetStagingError.writeFailed }
            try output.synchronize()

            let mapped = try Data(contentsOf: target, options: [.mappedIfSafe])
            let detected = try Self.detectedType(mapped)
            guard Self.mediaType(declaredMediaType, matches: detected.mediaType) else {
                throw AssetStagingError.declaredTypeMismatch
            }
            if let width = detected.width, let height = detected.height {
                guard width > 0, height > 0, width <= Self.maximumPixels / max(1, height) else {
                    throw AssetStagingError.tooManyPixels
                }
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let metadata = AssetMetadata(
                id: id,
                localRelativePath: relative,
                originalName: String(originalName.prefix(255)),
                mediaType: detected.mediaType,
                byteCount: copiedBytes,
                sha256: digest,
                width: detected.width,
                height: detected.height
            )
            try await store.registerAsset(metadata)
            try await store.linkDraftAsset(draftID: draftID, assetID: id)
            return metadata
        } catch let error as AssetStagingError {
            try? FileManager.default.removeItem(at: directory)
            throw error
        } catch let error as CaptureStoreError {
            try? FileManager.default.removeItem(at: directory)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw AssetStagingError.writeFailed
        }
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func mediaType(_ declared: String, matches detected: String) -> Bool {
        let value = declared.lowercased()
        if value == detected { return true }
        if detected == "image/jpeg" { return value == "image/jpg" }
        if detected == "image/heic" { return value == "image/heif" }
        return false
    }

    private static func detectedType(_ data: Data) throws -> (mediaType: String, width: Int?, height: Int?) {
        let mediaType: String
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            mediaType = "image/png"
        } else if data.count >= 3, data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF {
            mediaType = "image/jpeg"
        } else if data.count >= 6, String(decoding: data.prefix(6), as: UTF8.self).hasPrefix("GIF8") {
            mediaType = "image/gif"
        } else if data.count >= 12,
                  String(decoding: data.prefix(4), as: UTF8.self) == "RIFF",
                  String(decoding: data[8..<12], as: UTF8.self) == "WEBP" {
            mediaType = "image/webp"
        } else if data.count >= 12,
                  String(decoding: data[4..<8], as: UTF8.self) == "ftyp",
                  ["heic", "heix", "hevc", "hevx", "mif1"].contains(String(decoding: data[8..<12], as: UTF8.self)) {
            mediaType = "image/heic"
        } else {
            throw AssetStagingError.unsupportedType
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw AssetStagingError.unsupportedType
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        return (mediaType, width, height)
    }
}
