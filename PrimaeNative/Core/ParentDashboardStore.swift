import Foundation

// MARK: - Data models

struct PhaseSessionRecord: Codable, Equatable {
    let letter: String
    /// LearningPhase.rawName: "observe", "direct", "guided", or "freeWrite".
    let phase: String
    let completed: Bool
    /// Phase accuracy score (0–1). For freeWrite equals WritingAssessment.overallScore.
    let score: Double
    /// Spaced-repetition priority assigned when this session was scheduled.
    let schedulerPriority: Double
    /// Thesis A/B condition in effect for this session. Added
    /// post-launch; custom decoder defaults pre-migration records to
    /// `.threePhase`.
    let condition: ThesisCondition
    /// Pilot audio arm in effect for this session (phoneme /
    /// spatial-sonification / silent). Orthogonal to `condition`. Added
    /// for the pilot; custom decoder defaults pre-migration records to
    /// `.phoneme`.
    let audioCondition: PilotAudioCondition
    /// Wall-clock timestamp when this row was recorded. Drives dated
    /// learning curves and pre-enrollment filtering. Optional because
    /// legacy records on disk don't carry it.
    let recordedAt: Date?
    /// Schreibmotorik dimensions (non-nil only for freeWrite sessions).
    let formAccuracy: Double?
    let tempoConsistency: Double?
    let pressureControl: Double?
    let rhythmScore: Double?
    /// Per-session recognition outcome captured at completion time.
    /// Only meaningful for freeWrite rows; nil otherwise and for
    /// legacy records.
    let recognitionPredicted: String?
    let recognitionConfidence: Double?
    /// Pre-calibration softmax confidence so analysis can quantify
    /// the calibrator's effect.
    let recognitionConfidenceRaw: Double?
    let recognitionCorrect: Bool?
    /// Input device ("finger" / "pencil") so a `pressureControl == 1.0`
    /// real finger session is distinguishable from a low-variance
    /// pencil session.
    let inputDevice: String?
    /// Link to the raw freeWrite trace in `RawTraceStore` (re-analysis
    /// insurance). Non-nil only on freeWrite rows that captured a trace;
    /// nil for other phases and for legacy records (decode-default).
    let rawTraceID: UUID?
    /// The participant's trained 3-of-5 study-letter subset
    /// (`TrainedLetterSubset.rawValue`, e.g. "AFI") so analysis can
    /// partition trained vs untrained letters per row. Nil for legacy
    /// records.
    let trainedSubset: String?
    /// Measured-phase duration in seconds — for freeWrite rows, the
    /// first-to-last raw-trace sample span (excludes the trailing 2.0 s
    /// quiet-window auto-advance by construction). Nil for other phases
    /// and legacy records.
    let phaseDurationSeconds: Double?
    /// **SECONDARY, sequence-sensitive process outcome** (2026-09-03:
    /// no longer primary — see `spatialDeviation` below). Raw discrete-
    /// Fréchet distance (Eiter & Mannila 1994) between the freeWrite
    /// trace and the reference glyph, both arc-length resampled to a
    /// common point count, in reference-normalised 0–1 units. Lower is
    /// better; 0 is a perfect overlay. Unbounded above and never
    /// clamped. Fréchet's DP walk couples trace-order to reference-order
    /// monotonically, so it reports a spatially correct letter written
    /// in an unusual stroke order as inaccurate — a process property
    /// (sequence), not the product property (form) its name suggested.
    /// Retained unchanged, as a named process outcome, rather than
    /// deleted: still derivable from the same raw traces, so no prior
    /// session's data is lost by the reclassification. Nil for
    /// non-freeWrite phases, legacy records, and traces too short to
    /// compare. See APP_DOCUMENTATION §4.12.
    let frechetDistance: Double?
    /// **PRIMARY accuracy outcome** (2026-09-03). Raw, ORDER-INVARIANT
    /// spatial deviation: symmetric Hausdorff distance between the
    /// freeWrite trace and the reference glyph (reference densified
    /// per-stroke), in the same reference-normalised 0–1 units as
    /// `frechetDistance` — see `FreeWriteScorer.rawSpatialDeviation` for
    /// the full rationale. Lower is better; unbounded above and never
    /// clamped, for the same statistical reason `frechetDistance` isn't
    /// (unlike `formAccuracy`, a rescaled/clamped transform of this same
    /// distance, it does not saturate at ceiling). Nil for non-freeWrite
    /// phases, legacy records, and traces too short to compare.
    let spatialDeviation: Double?
    /// **Secondary accuracy outcome.** Fraction of the reference's
    /// checkpoints reached during the measured freeWrite phase (0–1),
    /// from `StrokeTracker.overallProgress`. Retained alongside the
    /// primary because it is the measure the app's own UI and the
    /// earlier pilot rounds used — but it is bounded and saturates at
    /// 1.0, which is why it is not the primary. Nil for non-freeWrite
    /// phases and legacy records.
    let checkpointCoverage: Double?

    init(letter: String, phase: String, completed: Bool, score: Double,
         schedulerPriority: Double, condition: ThesisCondition = .threePhase,
         audioCondition: PilotAudioCondition = .phoneme,
         recordedAt: Date = Date(),
         assessment: WritingAssessment? = nil,
         recognition: RecognitionSample? = nil,
         inputDevice: String? = nil,
         rawTraceID: UUID? = nil,
         trainedSubset: String? = nil,
         phaseDurationSeconds: Double? = nil,
         frechetDistance: Double? = nil,
         checkpointCoverage: Double? = nil,
         spatialDeviation: Double? = nil) {
        self.letter = letter
        self.phase = phase
        self.completed = completed
        self.score = max(0, min(1, score))
        self.schedulerPriority = schedulerPriority
        self.condition = condition
        self.audioCondition = audioCondition
        self.recordedAt = recordedAt
        self.formAccuracy     = assessment.map { Double($0.formAccuracy) }
        self.tempoConsistency = assessment.map { Double($0.tempoConsistency) }
        self.pressureControl  = assessment.map { Double($0.pressureControl) }
        self.rhythmScore      = assessment.map { Double($0.rhythmScore) }
        self.recognitionPredicted    = recognition?.predictedLetter
        self.recognitionConfidence   = recognition?.confidence
        self.recognitionConfidenceRaw = recognition?.rawConfidence
        self.recognitionCorrect      = recognition?.isCorrect
        self.inputDevice             = inputDevice
        self.rawTraceID              = rawTraceID
        self.trainedSubset           = trainedSubset
        self.phaseDurationSeconds    = phaseDurationSeconds
        self.frechetDistance         = frechetDistance
        self.checkpointCoverage      = checkpointCoverage
        self.spatialDeviation        = spatialDeviation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        letter = try c.decode(String.self, forKey: .letter)
        phase = try c.decode(String.self, forKey: .phase)
        completed = try c.decode(Bool.self, forKey: .completed)
        score = try c.decode(Double.self, forKey: .score)
        schedulerPriority = try c.decode(Double.self, forKey: .schedulerPriority)
        condition = (try? c.decode(ThesisCondition.self, forKey: .condition)) ?? .threePhase
        // Pre-pilot records carry no audioCondition. Default to `.phoneme`:
        // the app has always played meaningful letter/phoneme sound (never
        // arbitrary, never silent), so it's the honest historical match.
        // Such legacy rows are pre-enrolment and the exporter filters them
        // from arm attribution anyway, so this default can't inflate a
        // pilot arm's counts. Rows written under the short-lived
        // `arbitrarySound` raw value (pre-`.spatial` rename; test devices
        // only — no study ran) fail the enum decode and take the same
        // `.phoneme` fallback.
        audioCondition = (try? c.decode(PilotAudioCondition.self, forKey: .audioCondition)) ?? .phoneme
        recordedAt = try? c.decode(Date.self, forKey: .recordedAt)
        formAccuracy     = try? c.decode(Double.self, forKey: .formAccuracy)
        tempoConsistency = try? c.decode(Double.self, forKey: .tempoConsistency)
        pressureControl  = try? c.decode(Double.self, forKey: .pressureControl)
        rhythmScore      = try? c.decode(Double.self, forKey: .rhythmScore)
        recognitionPredicted     = try? c.decode(String.self, forKey: .recognitionPredicted)
        recognitionConfidence    = try? c.decode(Double.self, forKey: .recognitionConfidence)
        recognitionConfidenceRaw = try? c.decode(Double.self, forKey: .recognitionConfidenceRaw)
        recognitionCorrect       = try? c.decode(Bool.self, forKey: .recognitionCorrect)
        inputDevice              = try? c.decode(String.self, forKey: .inputDevice)
        // Added with raw-trace capture; nil for legacy rows and non-trace
        // phases.
        rawTraceID               = try? c.decode(UUID.self, forKey: .rawTraceID)
        // Added with the 3-of-5 trained-subset design; nil for legacy rows.
        trainedSubset            = try? c.decode(String.self, forKey: .trainedSubset)
        phaseDurationSeconds     = try? c.decode(Double.self, forKey: .phaseDurationSeconds)
        // Added with the measurement layer; nil for legacy rows, which
        // is the honest value — those sessions never measured it.
        frechetDistance          = try? c.decode(Double.self, forKey: .frechetDistance)
        checkpointCoverage       = try? c.decode(Double.self, forKey: .checkpointCoverage)
        // Added 2026-09-03 with the order-invariant primary outcome;
        // nil for every record written before this — those sessions
        // never measured it, and their frechetDistance is what stays
        // re-derivable from raw traces if it's ever wanted retroactively.
        spatialDeviation         = try? c.decode(Double.self, forKey: .spatialDeviation)
    }
}

struct LetterAccuracyStat: Codable, Equatable {
    let letter: String
    /// Per-session accuracy samples (0–1), chronological order.
    let accuracySamples: [Double]
    /// Parallel array of the thesis condition active when each
    /// `accuracySamples[i]` was recorded. Length matches
    /// `accuracySamples.count` for new writes. Nil for legacy rows;
    /// the exporter falls back to per-row condition derivation from
    /// `phaseSessionRecords` for those.
    let accuracyConditions: [ThesisCondition]?

    init(letter: String, accuracySamples: [Double],
         accuracyConditions: [ThesisCondition]? = nil) {
        self.letter = letter
        self.accuracySamples = accuracySamples
        self.accuracyConditions = accuracyConditions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        letter = try c.decode(String.self, forKey: .letter)
        accuracySamples = try c.decode([Double].self, forKey: .accuracySamples)
        accuracyConditions = try? c.decode([ThesisCondition].self, forKey: .accuracyConditions)
    }

    var averageAccuracy: Double {
        guard !accuracySamples.isEmpty else { return 0 }
        return accuracySamples.reduce(0, +) / Double(accuracySamples.count)
    }
    var trend: Double {
        // Slope of simple linear regression over last min(10, n) samples.
        let window = Array(accuracySamples.suffix(10))
        guard window.count >= 2 else { return 0 }
        let n = Double(window.count)
        let xs = (0..<window.count).map { Double($0) }
        let xMean = xs.reduce(0, +) / n
        let yMean = window.reduce(0, +) / n
        let numerator = zip(xs, window).reduce(0.0) { $0 + ($1.0 - xMean) * ($1.1 - yMean) }
        let denominator = xs.reduce(0.0) { $0 + ($1 - xMean) * ($1 - xMean) }
        return denominator == 0 ? 0 : numerator / denominator
    }
}

struct SessionDurationRecord: Codable, Equatable {
    /// ISO-8601 date string "yyyy-MM-dd"
    let dateString: String
    /// Active practice time in seconds. Pauses while the app is
    /// backgrounded so this reflects actual on-task time.
    let durationSeconds: TimeInterval
    /// Wall-clock duration including backgrounded intervals — lets
    /// analysis distinguish "engaged" from "actively practising".
    let wallClockSeconds: TimeInterval?
    /// Thesis condition active during this session.
    let condition: ThesisCondition
    /// Full wall-clock timestamp at session-record time so the export
    /// recovers time-of-day signal on top of the day-level aggregation.
    let recordedAt: Date?
    /// Input device ("finger" / "pencil") so "minutes practised by
    /// device" can be aggregated without joining across record types.
    let inputDevice: String?
    /// The letter (or word label) this session practised. Added for the
    /// pilot's per-letter time-to-complete outcome — before this, the
    /// letter identity was dropped at storage and recoverable only via
    /// a fragile `recordedAt` join against the per-phase rows. Nil for
    /// legacy records.
    let letter: String?

    init(dateString: String, durationSeconds: TimeInterval,
         wallClockSeconds: TimeInterval? = nil,
         condition: ThesisCondition = .threePhase,
         recordedAt: Date? = Date(),
         inputDevice: String? = nil,
         letter: String? = nil) {
        self.dateString = dateString
        self.durationSeconds = durationSeconds
        self.wallClockSeconds = wallClockSeconds
        self.condition = condition
        self.recordedAt = recordedAt
        self.inputDevice = inputDevice
        self.letter = letter
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dateString = try c.decode(String.self, forKey: .dateString)
        durationSeconds = try c.decode(TimeInterval.self, forKey: .durationSeconds)
        wallClockSeconds = try? c.decode(TimeInterval.self, forKey: .wallClockSeconds)
        condition = (try? c.decode(ThesisCondition.self, forKey: .condition)) ?? .threePhase
        recordedAt = try? c.decode(Date.self, forKey: .recordedAt)
        inputDevice = try? c.decode(String.self, forKey: .inputDevice)
        letter = try? c.decode(String.self, forKey: .letter)
    }
}

struct DashboardSnapshot: Codable, Equatable {
    var letterStats: [String: LetterAccuracyStat] = [:]
    var sessionDurations: [SessionDurationRecord] = []
    var phaseSessionRecords: [PhaseSessionRecord] = []
    var schemaVersion: Int? = dashboardSchemaVersion

    init(letterStats: [String: LetterAccuracyStat] = [:],
         sessionDurations: [SessionDurationRecord] = [],
         phaseSessionRecords: [PhaseSessionRecord] = []) {
        self.letterStats = letterStats
        self.sessionDurations = sessionDurations
        self.phaseSessionRecords = phaseSessionRecords
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        letterStats = try c.decode([String: LetterAccuracyStat].self, forKey: .letterStats)
        sessionDurations = try c.decode([SessionDurationRecord].self, forKey: .sessionDurations)
        // phaseSessionRecords was added after initial release; default to empty for old JSON files.
        phaseSessionRecords = (try? c.decode([PhaseSessionRecord].self, forKey: .phaseSessionRecords)) ?? []
        schemaVersion = try? c.decode(Int.self, forKey: .schemaVersion)
    }

    /// Convenience: top 5 letters by average accuracy descending.
    var topLetters: [LetterAccuracyStat] {
        Array(letterStats.values
            .filter { !$0.accuracySamples.isEmpty }
            .sorted { $0.averageAccuracy > $1.averageAccuracy }
            .prefix(5))
    }
    /// Convenience: letters with accuracy below threshold.
    func lettersBelow(accuracy threshold: Double) -> [LetterAccuracyStat] {
        letterStats.values
            .filter { !$0.accuracySamples.isEmpty && $0.averageAccuracy < threshold }
            .sorted { $0.letter < $1.letter }
    }
    /// Rolling 7-day total practice time in seconds.
    func totalPracticeTime(recentDays: Int = 7, referenceDate: Date = Date(), calendar: Calendar = .current) -> TimeInterval {
        guard let cutoff = calendar.date(byAdding: .day, value: -recentDays, to: referenceDate) else { return 0 }
        let cutoffString = dayKey(for: cutoff, calendar: calendar)
        return sessionDurations
            .filter { $0.dateString >= cutoffString }
            .reduce(0) { $0 + $1.durationSeconds }
    }

    /// Fraction of sessions that completed each phase (keyed by
    /// `LearningPhase.rawName`). Iterates `LearningPhase.allCases` so
    /// every phase, including `direct`, lands in the export.
    var phaseCompletionRates: [String: Double] {
        var result: [String: Double] = [:]
        for phase in LearningPhase.allCases.map(\.rawName) {
            let records = phaseSessionRecords.filter { $0.phase == phase }
            guard !records.isEmpty else { continue }
            result[phase] = Double(records.filter { $0.completed }.count) / Double(records.count)
        }
        return result
    }

    /// Mean per-phase score for one letter, keyed by
    /// `LearningPhase.rawName`. Returns only phases with at least one
    /// completed session.
    func phaseScores(for letter: String) -> [String: Double] {
        let key = LetterProgress.canonicalKey(letter)
        let records = phaseSessionRecords.filter { LetterProgress.canonicalKey($0.letter) == key && $0.completed }
        guard !records.isEmpty else { return [:] }
        var sums: [String: (total: Double, count: Int)] = [:]
        for r in records {
            let prior = sums[r.phase] ?? (0, 0)
            sums[r.phase] = (prior.total + r.score, prior.count + 1)
        }
        return sums.mapValues { $0.total / Double($0.count) }
    }

    /// Daily practice minutes for the most recent `days` days. Missing
    /// days are filled with 0 so the chart x-axis is continuous.
    /// Oldest-first.
    func dailyPracticeMinutes(days: Int = 30,
                              referenceDate: Date = Date(),
                              calendar: Calendar = .current) -> [(date: Date, minutes: Double)] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = calendar.timeZone

        let byKey = Dictionary(grouping: sessionDurations, by: { $0.dateString })
            .mapValues { $0.reduce(0) { $0 + $1.durationSeconds } }

        var out: [(date: Date, minutes: Double)] = []
        for offset in (0..<days).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: referenceDate) else { continue }
            let key = formatter.string(from: day)
            let minutes = (byKey[key] ?? 0) / 60.0
            out.append((date: day, minutes: minutes))
        }
        return out
    }

    /// Mean overall score across all completed freeWrite phase sessions.
    var averageFreeWriteScore: Double {
        let scores = phaseSessionRecords
            .filter { $0.phase == LearningPhase.freeWrite.rawName && $0.completed }
            .map { $0.score }
        guard !scores.isEmpty else { return 0 }
        return scores.reduce(0, +) / Double(scores.count)
    }

    /// Average of each Schreibmotorik dimension across completed
    /// freeWrite sessions with dimension data, or nil if none exist.
    var averageWritingDimensions: (form: Double, tempo: Double, pressure: Double, rhythm: Double)? {
        let records = phaseSessionRecords
            .filter { $0.phase == LearningPhase.freeWrite.rawName && $0.completed && $0.formAccuracy != nil }
        guard !records.isEmpty else { return nil }
        let count = Double(records.count)
        return (
            form:     records.compactMap(\.formAccuracy).reduce(0, +)     / count,
            tempo:    records.compactMap(\.tempoConsistency).reduce(0, +) / count,
            pressure: records.compactMap(\.pressureControl).reduce(0, +)  / count,
            rhythm:   records.compactMap(\.rhythmScore).reduce(0, +)      / count
        )
    }

    /// Pearson correlation between scheduler priority and subsequent accuracy improvement.
    /// Positive values indicate the scheduler is correctly prioritising struggling letters.
    var schedulerEffectivenessProxy: Double {
        var pairs: [(priority: Double, delta: Double)] = []
        let letters = Set(phaseSessionRecords.map { $0.letter })
        for letter in letters {
            let records = phaseSessionRecords.filter { $0.letter == letter && $0.completed }
            guard records.count >= 2 else { continue }
            for i in 0..<(records.count - 1) {
                pairs.append((priority: records[i].schedulerPriority,
                               delta: records[i + 1].score - records[i].score))
            }
        }
        guard pairs.count >= 2 else { return 0 }
        let n = Double(pairs.count)
        let xs = pairs.map { $0.priority }
        let ys = pairs.map { $0.delta }
        let xMean = xs.reduce(0, +) / n
        let yMean = ys.reduce(0, +) / n
        let numerator = zip(xs, ys).reduce(0.0) { $0 + ($1.0 - xMean) * ($1.1 - yMean) }
        let xVar = xs.reduce(0.0) { $0 + ($1 - xMean) * ($1 - xMean) }
        let yVar = ys.reduce(0.0) { $0 + ($1 - yMean) * ($1 - yMean) }
        guard xVar > 0, yVar > 0 else { return 0 }
        return numerator / sqrt(xVar * yVar)
    }
}

// MARK: - Protocol

@MainActor
protocol ParentDashboardStoring {
    var snapshot: DashboardSnapshot { get }
    /// Records one completed letter session. `wallClockSeconds` covers
    /// backgrounded time so the export can distinguish active practice
    /// from engagement; `inputDevice` enables device-split aggregation.
    func recordSession(letter: String, accuracy: Double,
                       durationSeconds: TimeInterval,
                       wallClockSeconds: TimeInterval?,
                       date: Date, condition: ThesisCondition,
                       inputDevice: String?)
    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, audioCondition: PilotAudioCondition, assessment: WritingAssessment?, recognition: RecognitionSample?, inputDevice: String?, rawTraceID: UUID?, trainedSubset: String?, phaseDurationSeconds: Double?, frechetDistance: Double?, checkpointCoverage: Double?, spatialDeviation: Double?)
    func reset()
    /// Await any pending background write. See ProgressStoring.flush().
    func flush() async
}

extension ParentDashboardStoring {
    /// Backward-compatible overloads for call sites that don't supply an
    /// assessment / recognition / inputDevice. `audioCondition` defaults
    /// to `.phoneme`; the live VM path uses the full method and stamps the
    /// participant's assigned arm explicitly.
    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, audioCondition: PilotAudioCondition = .phoneme) {
        recordPhaseSession(letter: letter, phase: phase, completed: completed, score: score,
                           schedulerPriority: schedulerPriority, condition: condition, audioCondition: audioCondition, assessment: nil, recognition: nil, inputDevice: nil, rawTraceID: nil, trainedSubset: nil, phaseDurationSeconds: nil, frechetDistance: nil, checkpointCoverage: nil, spatialDeviation: nil)
    }
    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, audioCondition: PilotAudioCondition = .phoneme, assessment: WritingAssessment?) {
        recordPhaseSession(letter: letter, phase: phase, completed: completed, score: score,
                           schedulerPriority: schedulerPriority, condition: condition, audioCondition: audioCondition, assessment: assessment, recognition: nil, inputDevice: nil, rawTraceID: nil, trainedSubset: nil, phaseDurationSeconds: nil, frechetDistance: nil, checkpointCoverage: nil, spatialDeviation: nil)
    }
    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, audioCondition: PilotAudioCondition = .phoneme, assessment: WritingAssessment?, recognition: RecognitionSample?) {
        recordPhaseSession(letter: letter, phase: phase, completed: completed, score: score,
                           schedulerPriority: schedulerPriority, condition: condition, audioCondition: audioCondition, assessment: assessment, recognition: recognition, inputDevice: nil, rawTraceID: nil, trainedSubset: nil, phaseDurationSeconds: nil, frechetDistance: nil, checkpointCoverage: nil, spatialDeviation: nil)
    }
    /// Pre-3-of-5 full signature — forwards with no subset/duration so
    /// existing call sites and tests compile unchanged.
    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, audioCondition: PilotAudioCondition, assessment: WritingAssessment?, recognition: RecognitionSample?, inputDevice: String?, rawTraceID: UUID?) {
        recordPhaseSession(letter: letter, phase: phase, completed: completed, score: score,
                           schedulerPriority: schedulerPriority, condition: condition, audioCondition: audioCondition, assessment: assessment, recognition: recognition, inputDevice: inputDevice, rawTraceID: rawTraceID, trainedSubset: nil, phaseDurationSeconds: nil, frechetDistance: nil, checkpointCoverage: nil, spatialDeviation: nil)
    }
    /// Pre-measurement-layer full signature — forwards with no Fréchet
    /// distance / checkpoint coverage so existing call sites and tests
    /// compile unchanged.
    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, audioCondition: PilotAudioCondition, assessment: WritingAssessment?, recognition: RecognitionSample?, inputDevice: String?, rawTraceID: UUID?, trainedSubset: String?, phaseDurationSeconds: Double?) {
        recordPhaseSession(letter: letter, phase: phase, completed: completed, score: score,
                           schedulerPriority: schedulerPriority, condition: condition, audioCondition: audioCondition, assessment: assessment, recognition: recognition, inputDevice: inputDevice, rawTraceID: rawTraceID, trainedSubset: trainedSubset, phaseDurationSeconds: phaseDurationSeconds, frechetDistance: nil, checkpointCoverage: nil, spatialDeviation: nil)
    }
    /// Pre-order-invariant-primary full signature — forwards with no
    /// spatial deviation so existing call sites and tests compile
    /// unchanged.
    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, audioCondition: PilotAudioCondition = .phoneme, assessment: WritingAssessment?, recognition: RecognitionSample?, inputDevice: String?, rawTraceID: UUID?, trainedSubset: String?, phaseDurationSeconds: Double?, frechetDistance: Double?, checkpointCoverage: Double?) {
        recordPhaseSession(letter: letter, phase: phase, completed: completed, score: score,
                           schedulerPriority: schedulerPriority, condition: condition, audioCondition: audioCondition, assessment: assessment, recognition: recognition, inputDevice: inputDevice, rawTraceID: rawTraceID, trainedSubset: trainedSubset, phaseDurationSeconds: phaseDurationSeconds, frechetDistance: frechetDistance, checkpointCoverage: checkpointCoverage, spatialDeviation: nil)
    }
    /// Backward-compatible recordSession overload — new fields populate as nil.
    func recordSession(letter: String, accuracy: Double,
                       durationSeconds: TimeInterval, date: Date,
                       condition: ThesisCondition) {
        recordSession(letter: letter, accuracy: accuracy,
                      durationSeconds: durationSeconds,
                      wallClockSeconds: nil,
                      date: date, condition: condition,
                      inputDevice: nil)
    }
    func flush() async {}
}

// MARK: - JSON-persisted implementation

final class JSONParentDashboardStore: ParentDashboardStoring {

    private let fileURL: URL
    private let calendar: Calendar
    private(set) var snapshot: DashboardSnapshot
    private var pendingSave: Task<Void, Never>?

    init(fileURL: URL? = nil, calendar: Calendar = .current) {
        self.calendar = calendar
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
            self.fileURL = dir.appendingPathComponent("dashboard.json")
        }
        self.snapshot = Self.load(from: self.fileURL) ?? DashboardSnapshot()
    }

    /// Hard ceiling on per-letter accuracy samples — keeps the JSON
    /// file bounded on long-running deployments. The trend regression
    /// only reads the trailing 10.
    private static let accuracySamplesCap = 200

    /// Hard ceiling on phase-session records — dashboard summaries
    /// read recent windows only.
    private static let phaseSessionRecordsCap = 2000

    /// Hard ceiling on per-day session durations. ~3 years of headroom
    /// for the 30-day PracticeTrendChart window.
    private static let sessionDurationsCap = 1000

    func recordSession(letter: String, accuracy: Double,
                       durationSeconds: TimeInterval,
                       wallClockSeconds: TimeInterval? = nil,
                       date: Date, condition: ThesisCondition,
                       inputDevice: String? = nil) {
        let key = LetterProgress.canonicalKey(letter)
        // Word-mode sessions arrive with multi-character keys
        // (`"BUCH"`); adding those to `letterStats` would corrupt the
        // per-letter accuracy table. Per-letter contributions land via
        // `progressStore.recordCompletion` on each cell letter, so we
        // skip the letterStats update here but still record the
        // duration once for the whole word.
        if key.count == 1 {
            let existing = snapshot.letterStats[key] ?? LetterAccuracyStat(letter: key, accuracySamples: [], accuracyConditions: [])
            var samples = existing.accuracySamples
            samples.append(accuracy)
            // Parallel-length condition array. Legacy rows decoded with
            // `accuracyConditions == nil`; back-fill so writes line up.
            var conditions = existing.accuracyConditions
                ?? Array(repeating: ThesisCondition.threePhase, count: existing.accuracySamples.count)
            conditions.append(condition)
            if samples.count > Self.accuracySamplesCap {
                let drop = samples.count - Self.accuracySamplesCap
                samples.removeFirst(drop)
                conditions.removeFirst(drop)
            }
            snapshot.letterStats[key] = LetterAccuracyStat(
                letter: existing.letter,
                accuracySamples: samples,
                accuracyConditions: conditions
            )
        }

        if durationSeconds > 0 {
            let day = dayKey(for: date, calendar: calendar)
            snapshot.sessionDurations.append(
                SessionDurationRecord(dateString: day,
                                       durationSeconds: durationSeconds,
                                       wallClockSeconds: wallClockSeconds,
                                       condition: condition,
                                       recordedAt: date,
                                       inputDevice: inputDevice,
                                       letter: letter)
            )
            if snapshot.sessionDurations.count > Self.sessionDurationsCap {
                snapshot.sessionDurations.removeFirst(
                    snapshot.sessionDurations.count - Self.sessionDurationsCap
                )
            }
        }
        persist()
    }

    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, audioCondition: PilotAudioCondition = .phoneme, assessment: WritingAssessment?, recognition: RecognitionSample?, inputDevice: String? = nil, rawTraceID: UUID? = nil, trainedSubset: String? = nil, phaseDurationSeconds: Double? = nil, frechetDistance: Double? = nil, checkpointCoverage: Double? = nil, spatialDeviation: Double? = nil) {
        let record = PhaseSessionRecord(
            letter: LetterProgress.canonicalKey(letter),
            phase: phase,
            completed: completed,
            score: score,
            schedulerPriority: schedulerPriority,
            condition: condition,
            audioCondition: audioCondition,
            assessment: assessment,
            recognition: recognition,
            inputDevice: inputDevice,
            rawTraceID: rawTraceID,
            trainedSubset: trainedSubset,
            phaseDurationSeconds: phaseDurationSeconds,
            frechetDistance: frechetDistance,
            checkpointCoverage: checkpointCoverage,
            spatialDeviation: spatialDeviation
        )
        snapshot.phaseSessionRecords.append(record)
        if snapshot.phaseSessionRecords.count > Self.phaseSessionRecordsCap {
            snapshot.phaseSessionRecords.removeFirst(
                snapshot.phaseSessionRecords.count - Self.phaseSessionRecordsCap
            )
        }
        persist()
    }

    func reset() {
        snapshot = DashboardSnapshot()
        persist()
    }

    // MARK: Private

    private func persist() {
        // Encode on main, write off main. Caps keep the snapshot well
        // under 100 KB so main-actor encoding is cheap.
        //
        // Rapid-fire batching: when several persist() calls happen in
        // one runloop tick the cancel-and-replace chain coalesces
        // them into a single disk write — each successor cancels its
        // predecessor before the atomic write fires. See
        // ParentDashboardStoreTests for the regression guard.
        guard let data = try? JSONEncoder().encode(snapshot) else {
            storePersistenceLogger.warning("ParentDashboardStore encode failed — snapshot not persisted; every later session is lost silently without this line.")
            return
        }
        let url = fileURL
        // Coalesce + order: see ProgressStore.save() for rationale.
        let previous = pendingSave
        previous?.cancel()
        pendingSave = Task.detached(priority: .utility) {
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                storePersistenceLogger.warning(
                    "ParentDashboardStore disk write failed at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Await any pending background write. Required before reading the file
    /// from another store instance.
    func flush() async {
        await pendingSave?.value
    }

    private static func load(from url: URL) -> DashboardSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(DashboardSnapshot.self, from: data)
        else { return nil }
        // Refuse files written by a future schema rather than
        // mis-decoding them. See ProgressStore.load.
        if let v = decoded.schemaVersion, v > dashboardSchemaVersion {
            storePersistenceLogger.warning(
                "ParentDashboardStore at \(url.path, privacy: .public) is schema v\(v) but build expects v\(dashboardSchemaVersion); ignoring on-disk state.")
            return nil
        }
        return decoded
    }
}

/// Current on-disk schema for `DashboardSnapshot`.
let dashboardSchemaVersion = 1

// MARK: - Helpers

private func dayKey(for date: Date, calendar: Calendar) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}
