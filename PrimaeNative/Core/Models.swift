import CoreGraphics

struct LetterAsset: Identifiable, Equatable {
    let id: String
    let name: String
    /// Grouping key — always the uppercase letter (e.g. "A" for both "A" and "a").
    let baseLetter: String
    let letterCase: LetterCase
    let audioFiles: [String]
    /// Phoneme recordings — the *sound* the letter makes (/a/ as in
    /// *Affe*) rather than its name (/aː/). Cycled when the parent
    /// enables "Lautwert wiedergeben"; falls back to `audioFiles` when
    /// empty. Filename convention `<base>_phoneme<n>.mp3`.
    let phonemeAudioFiles: [String]
    let strokes: LetterStrokes
    /// Variant IDs for which a strokes_{id}.json exists alongside
    /// strokes.json (e.g. Austrian Schulschrift 1995).
    let variants: [String]?

    enum LetterCase: String, Codable, Equatable, Sendable {
        case upper, lower
    }

    /// Convenience init preserving backward compatibility (defaults to .upper, no variants).
    init(id: String, name: String,
         audioFiles: [String], strokes: LetterStrokes,
         phonemeAudioFiles: [String] = []) {
        self.id = id
        self.name = name
        self.baseLetter = name.uppercased()
        self.letterCase = .upper
        self.audioFiles = audioFiles
        self.phonemeAudioFiles = phonemeAudioFiles
        self.strokes = strokes
        self.variants = nil
    }

    /// Full init with case specification and optional variants.
    init(id: String, name: String, baseLetter: String,
         letterCase: LetterCase,
         audioFiles: [String], strokes: LetterStrokes,
         variants: [String]? = nil,
         phonemeAudioFiles: [String] = []) {
        self.id = id
        self.name = name
        self.baseLetter = baseLetter
        self.letterCase = letterCase
        self.audioFiles = audioFiles
        self.phonemeAudioFiles = phonemeAudioFiles
        self.strokes = strokes
        self.variants = variants
    }
}

struct LetterStrokes: Codable, Equatable {
    let letter: String
    let checkpointRadius: CGFloat
    let strokes: [StrokeDefinition]
    /// Bbox-relative centerline point cloud (subsampled medial axis of
    /// the rendered glyph). Optional — older bundles and user-saved
    /// calibrations omit it. The calibrator's record mode uses these
    /// to snap a wobbly hand-traced sketch onto the actual ink centerline.
    let skeleton: [Checkpoint]?
    /// Adjacency list parallel to `skeleton`: `skeletonAdj[i]` holds
    /// the indices of skeleton pixels that are direct (≤ 3 px) neighbours
    /// of pixel `i`. Drives the calibrator's "tap a few points, BFS
    /// along the centerline between them" anchor mode.
    let skeletonAdj: [[Int]]?
    /// Routing-only edges between skeleton pixels that bridge gaps left
    /// by the Phase 3 skeleton split. Pairs of indices into `skeleton`.
    /// The calibrator unions these into the adjacency graph for BFS
    /// routing only — the red-dot viz does NOT draw bridge edges. Lets
    /// the anchor-snap workflow route across former cluster gaps that
    /// the split intentionally opened for visualization clarity.
    let bridgeEdges: [[Int]]?

    init(letter: String, checkpointRadius: CGFloat,
         strokes: [StrokeDefinition],
         skeleton: [Checkpoint]? = nil,
         skeletonAdj: [[Int]]? = nil,
         bridgeEdges: [[Int]]? = nil) {
        self.letter = letter
        self.checkpointRadius = checkpointRadius
        self.strokes = strokes
        self.skeleton = skeleton
        self.skeletonAdj = skeletonAdj
        self.bridgeEdges = bridgeEdges
    }
}

struct StrokeDefinition: Codable, Equatable {
    let id: Int
    let checkpoints: [Checkpoint]
}

struct Checkpoint: Codable, Equatable {
    let x: CGFloat
    let y: CGFloat
}

struct TracingPoint: Equatable {
    let location: CGPoint
    let time: CFTimeInterval
}
