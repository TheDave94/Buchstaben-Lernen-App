import Foundation

// MARK: - Typed errors

enum LetterRepositoryError: Error, Equatable {
    case noAssetsFound
    case partialLoad(loaded: Int, issues: [String])
    case cacheCorrupted(underlying: String)
    case cacheReadFailed(path: String)
}

// MARK: - Cache protocol (testable seam)

protocol LetterCacheStoring {
    func save(_ letters: [LetterAsset]) throws(LetterRepositoryError)
    func load() throws(LetterRepositoryError) -> [LetterAsset]
    func clear()
}

// MARK: - JSON disk cache

struct JSONLetterCache: LetterCacheStoring {

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let url = fileURL {
            self.fileURL = url
        } else {
            // See ProgressStore.init for the `??` fallback rationale.
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            let dir = support.appendingPathComponent("PrimaeNative", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("letter-cache.json")
        }
    }

    func save(_ letters: [LetterAsset]) throws(LetterRepositoryError) {
        do {
            let data = try JSONEncoder().encode(letters.map(CodableLetterAsset.init))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw LetterRepositoryError.cacheCorrupted(underlying: error.localizedDescription)
        }
    }

    func load() throws(LetterRepositoryError) -> [LetterAsset] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw LetterRepositoryError.cacheReadFailed(path: fileURL.path)
        }
        do {
            let data    = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([CodableLetterAsset].self, from: data)
            return decoded.map(\.asset)
        } catch {
            throw LetterRepositoryError.cacheCorrupted(underlying: error.localizedDescription)
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - Codable bridge for LetterAsset

/// `LetterAsset` uses `CGFloat`; bridge via `Double` for clean JSON.
private struct CodableLetterAsset: Codable {
    let id: String
    let name: String
    let baseLetter: String?
    let letterCase: LetterAsset.LetterCase?
    let audioFiles: [String]
    let phonemeAudioFiles: [String]?
    /// Optional for backward-compatible decode of caches written before
    /// the pilot's arbitrary-sound arm existed (decode → []).
    let arbitraryAudioFiles: [String]?
    let strokes: LetterStrokes
    let variants: [String]?

    init(_ asset: LetterAsset) {
        id                  = asset.id
        name                = asset.name
        baseLetter          = asset.baseLetter
        letterCase          = asset.letterCase
        audioFiles          = asset.audioFiles
        phonemeAudioFiles   = asset.phonemeAudioFiles
        arbitraryAudioFiles = asset.arbitraryAudioFiles
        strokes             = asset.strokes
        variants            = asset.variants
    }

    var asset: LetterAsset {
        LetterAsset(
            id: id,
            name: name,
            baseLetter: baseLetter ?? name.uppercased(),
            letterCase: letterCase ?? .upper,
            audioFiles: audioFiles,
            strokes: strokes,
            variants: variants,
            phonemeAudioFiles: phonemeAudioFiles ?? [],
            arbitraryAudioFiles: arbitraryAudioFiles ?? []
        )
    }
}
