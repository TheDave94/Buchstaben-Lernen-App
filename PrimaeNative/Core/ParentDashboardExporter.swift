import Foundation

// MARK: - Export format

enum DashboardExportFormat {
    case csv
    /// Tab-separated variant of `csv`. SPSS / R import TSV without the
    /// escape-quoting confusion CSVs hit on comma-bearing fields.
    case tsv
    case json
}

// MARK: - Typed export errors

enum ExportError: Error, Equatable {
    case encodingFailed(String)
    case writeFailed(String)
}

// MARK: - Exporter

/// Converts a ``DashboardSnapshot`` to shareable file data.
/// No UIKit/SwiftUI dependency — kept in Core so it's testable on Linux CI.
struct ParentDashboardExporter {

    // MARK: CSV / TSV

    /// Produces a UTF-8 CSV with a `# participantId=...` header, one
    /// row per letter, per-session durations, per-phase records, and
    /// aggregate thesis metrics. The participantId header lets A/B
    /// analysis align data across installs.
    static func csvData(from snapshot: DashboardSnapshot,
                         participantId: UUID = ParticipantStore.participantId,
                         progress: [String: LetterProgress] = [:],
                         enrolledAt: Date? = ParticipantStore.enrolledAt) -> Data {
        delimitedData(from: snapshot, participantId: participantId,
                       progress: progress, enrolledAt: enrolledAt, separator: ",")
    }

    /// Tab-separated variant of `csvData`. Same row layout.
    static func tsvData(from snapshot: DashboardSnapshot,
                         participantId: UUID = ParticipantStore.participantId,
                         progress: [String: LetterProgress] = [:],
                         enrolledAt: Date? = ParticipantStore.enrolledAt) -> Data {
        delimitedData(from: snapshot, participantId: participantId,
                       progress: progress, enrolledAt: enrolledAt, separator: "\t")
    }

    /// Shared row builder behind csvData / tsvData. Single
    /// implementation keeps both formats in lock-step on columns.
    private static func delimitedData(
        from snapshot: DashboardSnapshot,
        participantId: UUID,
        progress: [String: LetterProgress],
        enrolledAt: Date?,
        separator sep: String
    ) -> Data {
        var lines: [String] = []
        lines.append("# participantId=\(participantId.uuidString)")
        // Enrolment timestamp lets consumers reproduce the
        // pre-enrollment filtering rule and audit skipped records.
        if let enrolledAt {
            lines.append("# enrolledAt=\(ISO8601DateFormatter().string(from: enrolledAt))")
        }
        // Timezone label for cross-timezone / DST-aware interpretation.
        lines.append("# timezone=\(TimeZone.current.identifier)")
        let isoFormatter = ISO8601DateFormatter()
        lines.append("")

        // Letter-aggregate columns:
        //   speedTrend — semicolon-joined per-letter writing-speed
        //                series feeding the automatisation bonus.
        //   freeformCompletionCount — blank-canvas completions tracked
        //                separately from guided mastery.
        //   retrievalAccuracy — rolling mean of retrievalAttempts (cap 10).
        lines.append(["letter","sessionCount","averageAccuracy","trend","recognitionSamples","recognitionAvg","speedTrend","freeformCompletionCount","retrievalAccuracy"].joined(separator: sep))
        let sorted = snapshot.letterStats.values.sorted { $0.letter < $1.letter }
        for stat in sorted {
            let avg = String(format: "%.4f", stat.averageAccuracy)
            let tnd = String(format: "%.6f", stat.trend)
            let cnt = stat.accuracySamples.count
            let prog = progress[stat.letter]
            let acc = prog?.recognitionAccuracy ?? []
            let recCount = acc.count
            let recAvg = acc.isEmpty
                ? "" : String(format: "%.4f", acc.reduce(0, +) / Double(acc.count))
            let speedField = (prog?.speedTrend ?? [])
                .map { String(format: "%.4f", $0) }
                .joined(separator: ";")
            let freeformField = prog?.freeformCompletionCount.map { String($0) } ?? ""
            let retrievalField: String = {
                guard let attempts = prog?.retrievalAttempts, !attempts.isEmpty else { return "" }
                let acc = Double(attempts.filter { $0 }.count) / Double(attempts.count)
                return String(format: "%.4f", acc)
            }()
            lines.append([stat.letter, "\(cnt)", avg, tnd, "\(recCount)", recAvg, speedField, freeformField, retrievalField].joined(separator: sep))
        }
        lines.append("")

        // Full ISO-8601 timestamp alongside day-level dateString lets
        // analysis recover time-of-day signal. wallClockSeconds covers
        // backgrounded intervals so engagement-vs-practice is
        // recoverable. Legacy rows emit empty strings for new columns.
        lines.append(["date","recordedAt","durationSeconds","wallClockSeconds","condition","inputDevice"].joined(separator: sep))
        for rec in snapshot.sessionDurations.sorted(by: { $0.dateString < $1.dateString }) {
            let recordedAtField = rec.recordedAt.map { isoFormatter.string(from: $0) } ?? ""
            let wallField = rec.wallClockSeconds.map { String(format: "%.3f", $0) } ?? ""
            lines.append([rec.dateString, recordedAtField,
                          String(format: "%.3f", rec.durationSeconds),
                          wallField, rec.condition.rawValue,
                          rec.inputDevice ?? ""].joined(separator: sep))
        }
        lines.append("")

        // Per-phase rows carry the four Schreibmotorik dimensions
        // (formAccuracy / tempoConsistency / pressureControl /
        // rhythmScore) — non-null only for freeWrite rows. Legacy
        // rows decode the new fields as nil and emit empty strings.
        // `inputDevice` ("finger" / "pencil") distinguishes a true
        // finger session from a low-variance pencil session.
        // `recognition_confidence_raw` is the pre-calibration softmax
        // probability, used to quantify the calibrator's effect.
        // `audioCondition` (pilot audio arm) is appended last so the
        // legacy column order is preserved for existing consumers.
        lines.append(["letter","phase","completed","score","schedulerPriority","condition","recordedAt","recognition_predicted","recognition_confidence","recognition_confidence_raw","recognition_correct","formAccuracy","tempoConsistency","pressureControl","rhythmScore","inputDevice","audioCondition"].joined(separator: sep))
        for rec in snapshot.phaseSessionRecords {
            // Discard rows from before enrolment so pilot/sandbox
            // activity isn't attributed to the assigned arm. Also
            // discard rows lacking `recordedAt` when an `enrolledAt`
            // exists — they default to `.threePhase` and would
            // silently inflate that arm.
            if let enrolledAt {
                if let ts = rec.recordedAt {
                    if ts < enrolledAt { continue }
                } else {
                    continue
                }
            }
            let score = String(format: "%.4f", rec.score)
            let prio  = String(format: "%.4f", rec.schedulerPriority)
            let recordedAtField = rec.recordedAt.map { isoFormatter.string(from: $0) } ?? ""
            let recLabel = rec.recognitionPredicted ?? ""
            let recConf  = rec.recognitionConfidence.map { String(format: "%.4f", $0) } ?? ""
            let recConfRaw = rec.recognitionConfidenceRaw.map { String(format: "%.4f", $0) } ?? ""
            let recRight = rec.recognitionCorrect.map { String($0) } ?? ""
            let dimForm   = rec.formAccuracy.map     { String(format: "%.4f", $0) } ?? ""
            let dimTempo  = rec.tempoConsistency.map { String(format: "%.4f", $0) } ?? ""
            let dimPress  = rec.pressureControl.map  { String(format: "%.4f", $0) } ?? ""
            let dimRhythm = rec.rhythmScore.map      { String(format: "%.4f", $0) } ?? ""
            lines.append([
                rec.letter, rec.phase, "\(rec.completed)", score, prio,
                rec.condition.rawValue, recordedAtField,
                recLabel, recConf, recConfRaw, recRight,
                dimForm, dimTempo, dimPress, dimRhythm,
                rec.inputDevice ?? "",
                rec.audioCondition.rawValue
            ].joined(separator: sep))
        }
        lines.append("")

        lines.append(["metric","value"].joined(separator: sep))
        let rates = snapshot.phaseCompletionRates
        // Iterate LearningPhase.allCases so every phase, including
        // `direct`, lands in the export.
        for phase in LearningPhase.allCases.map(\.rawName) {
            if let rate = rates[phase] {
                lines.append(["phaseCompletionRate_\(phase)", String(format: "%.4f", rate)].joined(separator: sep))
            }
        }
        lines.append(["averageFreeWriteScore", String(format: "%.4f", snapshot.averageFreeWriteScore)].joined(separator: sep))
        lines.append(["schedulerEffectivenessProxy", String(format: "%.4f", snapshot.schedulerEffectivenessProxy)].joined(separator: sep))
        // Per-condition aggregates so between-arm comparisons don't
        // have to back out cross-arm contamination. The proxy is
        // meaningful only inside an arm — `.control` uses a different
        // priority scale, so the cross-arm proxy is invalid.
        for arm in ThesisCondition.allCases {
            let armRecords = snapshot.phaseSessionRecords.filter { $0.condition == arm }
            let freeWrite = armRecords.filter { $0.phase == "freeWrite" && $0.completed }.map(\.score)
            if !freeWrite.isEmpty {
                let avg = freeWrite.reduce(0, +) / Double(freeWrite.count)
                lines.append(["averageFreeWriteScore_\(arm.rawValue)", String(format: "%.4f", avg)].joined(separator: sep))
            }
            // Per-arm proxy: same Pearson as `schedulerEffectivenessProxy`,
            // restricted to one condition. Skipped under 2 pairs.
            var pairs: [(priority: Double, delta: Double)] = []
            let lettersInArm = Set(armRecords.map(\.letter))
            for letter in lettersInArm {
                let chrono = armRecords.filter { $0.letter == letter && $0.completed }
                guard chrono.count >= 2 else { continue }
                for i in 0..<(chrono.count - 1) {
                    pairs.append((priority: chrono[i].schedulerPriority,
                                  delta: chrono[i + 1].score - chrono[i].score))
                }
            }
            if pairs.count >= 2 {
                let n = Double(pairs.count)
                let xs = pairs.map(\.priority)
                let ys = pairs.map(\.delta)
                let xMean = xs.reduce(0, +) / n
                let yMean = ys.reduce(0, +) / n
                let num = zip(xs, ys).reduce(0.0) { $0 + ($1.0 - xMean) * ($1.1 - yMean) }
                let xVar = xs.reduce(0.0) { $0 + ($1 - xMean) * ($1 - xMean) }
                let yVar = ys.reduce(0.0) { $0 + ($1 - yMean) * ($1 - yMean) }
                if xVar > 0, yVar > 0 {
                    let r = num / (xVar * yVar).squareRoot()
                    lines.append(["schedulerEffectivenessProxy_\(arm.rawValue)", String(format: "%.4f", r)].joined(separator: sep))
                }
            }
        }
        // Per-letter accuracy aggregates split by thesis arm. The
        // letter-row `averageAccuracy` above mixes arms because
        // `letterStats.accuracySamples` carries no condition tag;
        // `phaseSessionRecords` does, so it gives a clean per-arm
        // letter-level source. Format:
        // `letterByArm,letter,arm,sampleCount,averageScore`.
        lines.append(["letterByArm","letter","arm","sampleCount","averageScore"].joined(separator: sep))
        let phaseByArm = Dictionary(grouping: snapshot.phaseSessionRecords.filter(\.completed), by: { $0.condition })
        for arm in ThesisCondition.allCases {
            guard let records = phaseByArm[arm] else { continue }
            let byLetter = Dictionary(grouping: records, by: { $0.letter })
            for (letter, group) in byLetter.sorted(by: { $0.key < $1.key }) {
                let n = group.count
                let avg = group.map(\.score).reduce(0, +) / Double(n)
                lines.append(["letterByArm", letter, arm.rawValue, "\(n)", String(format: "%.4f", avg)].joined(separator: sep))
            }
        }
        // Pilot audio axis — the PRIMARY between-subjects IV (the
        // pedagogical axis above is held constant across pilot arms, D1).
        // Stratified ALONGSIDE the pedagogical axis, not instead of it, so
        // both the pilot's audio contrast and the larger study's
        // pedagogical contrast stay exportable from one file.
        for arm in PilotAudioCondition.allCases {
            let armRecords = snapshot.phaseSessionRecords.filter { $0.audioCondition == arm }
            let freeWrite = armRecords.filter { $0.phase == "freeWrite" && $0.completed }.map(\.score)
            if !freeWrite.isEmpty {
                let avg = freeWrite.reduce(0, +) / Double(freeWrite.count)
                lines.append(["averageFreeWriteScore_audio_\(arm.rawValue)", String(format: "%.4f", avg)].joined(separator: sep))
            }
        }
        // Per-letter accuracy split by audio arm — the audio-axis twin of
        // `letterByArm`. Format:
        // `letterByAudioArm,letter,audioArm,sampleCount,averageScore`.
        lines.append(["letterByAudioArm","letter","audioArm","sampleCount","averageScore"].joined(separator: sep))
        let phaseByAudioArm = Dictionary(grouping: snapshot.phaseSessionRecords.filter(\.completed), by: { $0.audioCondition })
        for arm in PilotAudioCondition.allCases {
            guard let records = phaseByAudioArm[arm] else { continue }
            let byLetter = Dictionary(grouping: records, by: { $0.letter })
            for (letter, group) in byLetter.sorted(by: { $0.key < $1.key }) {
                let n = group.count
                let avg = group.map(\.score).reduce(0, +) / Double(n)
                lines.append(["letterByAudioArm", letter, arm.rawValue, "\(n)", String(format: "%.4f", avg)].joined(separator: sep))
            }
        }
        // Aggregate Schreibmotorik dimensions across all completed
        // freeWrite sessions. Emitted only when at least one session
        // contributed.
        if let dims = snapshot.averageWritingDimensions {
            lines.append(["averageFormAccuracy", String(format: "%.4f", dims.form)].joined(separator: sep))
            lines.append(["averageTempoConsistency", String(format: "%.4f", dims.tempo)].joined(separator: sep))
            lines.append(["averagePressureControl", String(format: "%.4f", dims.pressure)].joined(separator: sep))
            lines.append(["averageRhythmScore", String(format: "%.4f", dims.rhythm)].joined(separator: sep))
        }
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    // MARK: JSON

    /// Pretty-printed JSON of the full snapshot plus thesis metrics,
    /// `participantId`, and per-letter progress entries.
    static func jsonData(from snapshot: DashboardSnapshot,
                          participantId: UUID = ParticipantStore.participantId,
                          progress: [String: LetterProgress] = [:]) throws(ExportError) -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting    = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let export = SnapshotWithMetrics(
                snapshot: snapshot,
                participantId: participantId,
                progress: progress
            )
            return try encoder.encode(export)
        } catch {
            throw ExportError.encodingFailed(error.localizedDescription)
        }
    }

    // MARK: Private types

    private struct SnapshotWithMetrics: Encodable {
        let participantId: String
        let letterStats: [String: LetterAccuracyStat]
        let sessionDurations: [SessionDurationRecord]
        let phaseSessionRecords: [PhaseSessionRecord]
        let letterProgress: [String: LetterProgress]
        let thesisMetrics: ThesisMetrics

        init(snapshot: DashboardSnapshot,
             participantId: UUID,
             progress: [String: LetterProgress]) {
            self.participantId = participantId.uuidString
            letterStats = snapshot.letterStats
            sessionDurations = snapshot.sessionDurations
            phaseSessionRecords = snapshot.phaseSessionRecords
            letterProgress = progress
            let dims = snapshot.averageWritingDimensions
            thesisMetrics = ThesisMetrics(
                phaseCompletionRates: snapshot.phaseCompletionRates,
                averageFreeWriteScore: snapshot.averageFreeWriteScore,
                schedulerEffectivenessProxy: snapshot.schedulerEffectivenessProxy,
                averageFormAccuracy: dims?.form,
                averageTempoConsistency: dims?.tempo,
                averagePressureControl: dims?.pressure,
                averageRhythmScore: dims?.rhythm
            )
        }

        struct ThesisMetrics: Encodable {
            let phaseCompletionRates: [String: Double]
            let averageFreeWriteScore: Double
            let schedulerEffectivenessProxy: Double
            /// Schreibmotorik dimensions averaged across all completed
            /// freeWrite sessions. nil when no freeWrite data exists yet.
            let averageFormAccuracy: Double?
            let averageTempoConsistency: Double?
            let averagePressureControl: Double?
            let averageRhythmScore: Double?
        }
    }

    // MARK: File URL helpers

    /// Writes export data to a temp file and returns its URL for share-sheet use.
    static func exportFileURL(
        from snapshot: DashboardSnapshot,
        format: DashboardExportFormat,
        tempDirectory: URL = FileManager.default.temporaryDirectory,
        progress: [String: LetterProgress] = [:]
    ) throws(ExportError) -> URL {
        let data: Data
        let filename: String
        let dateTag = Self.dateTag()
        switch format {
        case .csv:
            data     = csvData(from: snapshot, progress: progress)
            filename = "primae_progress_\(dateTag).csv"
        case .tsv:
            data     = tsvData(from: snapshot, progress: progress)
            filename = "primae_progress_\(dateTag).tsv"
        case .json:
            data     = try jsonData(from: snapshot, progress: progress)
            filename = "primae_progress_\(dateTag).json"
        }
        let url = tempDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        return url
    }

    // MARK: Private

    private static func dateTag() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
