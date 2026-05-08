import Testing
import Foundation
@testable import PrimaeNative

private final class MockResourceProvider: LetterResourceProviding {
    var bundle: Bundle = .main
    var searchBundles: [Bundle] { [bundle] }
    private var resources: [String: URL] = [:]

    func add(_ filename: String) {
        resources[filename] = URL(string: "file:///mock/\(filename)")!
    }

    func allResourceURLs() -> [URL] { Array(resources.values) }

    func resourceURL(for relativePath: String) -> URL? {
        let key = (relativePath as NSString).lastPathComponent
        return resources[key]
    }
}

private func makeJSON(letter: String, radius: Double = 0.06) -> Data {
    let json = """
    {
      "letter": "\(letter)",
      "checkpointRadius": \(radius),
      "strokes": [
        { "id": 1, "checkpoints": [{"x": 0.3, "y": 0.8}, {"x": 0.7, "y": 0.2}] }
      ]
    }
    """
    return json.data(using: .utf8)!
}

private extension MockResourceProvider {
    func addLetter(_ base: String) {
        let jsonName = "\(base)_strokes.json"
        let tmp = FileManager.default.temporaryDirectory
        let jsonURL = tmp.appendingPathComponent(jsonName)
        try? makeJSON(letter: base).write(to: jsonURL)
        resources[jsonName] = jsonURL
        let pathURL = URL(fileURLWithPath: "/mock/\(base)/\(base)1.mp3")
        resources["\(base)/\(base)1.mp3"] = pathURL
    }
}

@MainActor
struct LetterRepositoryTests {

    @Test func emptyProvider_returnsFallbackLetter() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        let letters = repo.loadLetters()
        #expect(!letters.isEmpty, "loadLetters() must never return empty — fallback expected")
        #expect(letters.first?.id == "A", "Fallback must be letter A")
    }

    @Test func fallbackLetter_hasRequiredFields() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        let letter = repo.loadLetters().first!
        #expect(!letter.name.isEmpty)
        #expect(!letter.audioFiles.isEmpty)
    }

    @Test func invalidJSON_isSkipped_returnsAtLeastFallback() {
        class BadProvider: LetterResourceProviding {
            var bundle: Bundle = .main
            var searchBundles: [Bundle] { [bundle] }
            let badURL: URL
            init(url: URL) { badURL = url }
            func allResourceURLs() -> [URL] { [badURL] }
            func resourceURL(for relativePath: String) -> URL? { nil }
        }
        let badURL = FileManager.default.temporaryDirectory.appendingPathComponent("X_strokes.json")
        try? "{{invalid}}".data(using: .utf8)?.write(to: badURL)
        let repo = LetterRepository(resources: BadProvider(url: badURL), cache: NullLetterCache())
        #expect(!repo.loadLetters().isEmpty)
    }

    @Test func letterAsset_names_areNonEmpty() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        for letter in repo.loadLetters() {
            #expect(!letter.name.isEmpty)
        }
    }

    @Test func letterAsset_audioFiles_areNonEmpty() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        for letter in repo.loadLetters() {
            #expect(!letter.audioFiles.isEmpty, "letter \(letter.name) has no audio files")
        }
    }

    @Test func defaultStrokes_checkpoints_areNormalized() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        for letter in repo.loadLetters() {
            for stroke in letter.strokes.strokes {
                for cp in stroke.checkpoints {
                    #expect(cp.x >= 0.0); #expect(cp.x <= 1.0)
                    #expect(cp.y >= 0.0); #expect(cp.y <= 1.0)
                }
            }
        }
    }

    @Test func defaultStrokes_checkpointRadius_isPositive() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        for letter in repo.loadLetters() {
            #expect(letter.strokes.checkpointRadius > 0.0)
        }
    }

    @Test func loadLetters_noDuplicateIds() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        let ids = repo.loadLetters().map(\.id)
        #expect(ids.count == Set(ids).count, "loadLetters() must not return duplicate ids")
    }

    @Test func loadLetters_isIdempotent() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        #expect(repo.loadLetters() == repo.loadLetters())
    }

    @Test func letterAsset_equatable() {
        let a = LetterAsset(id: "A", name: "A",
                            audioFiles: ["A.mp3"], strokes: LetterStrokes(letter: "A", checkpointRadius: 0.06, strokes: []))
        let b = LetterAsset(id: "A", name: "A",
                            audioFiles: ["A.mp3"], strokes: LetterStrokes(letter: "A", checkpointRadius: 0.06, strokes: []))
        #expect(a == b)
    }
}
