import Testing
import Foundation
@testable import PrimaeNative

@MainActor
struct ParentDashboardExporterTests {

    private func makeSnapshot() -> DashboardSnapshot {
        let store = JSONParentDashboardStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_dashboard_\(UUID().uuidString).json"))
        store.recordSession(letter: "A", accuracy: 0.9, durationSeconds: 60, date: date("2026-03-01"), condition: .threePhase)
        store.recordSession(letter: "A", accuracy: 0.8, durationSeconds: 45, date: date("2026-03-02"), condition: .threePhase)
        store.recordSession(letter: "B", accuracy: 0.5, durationSeconds: 30, date: date("2026-03-01"), condition: .threePhase)
        return store.snapshot
    }

    private func date(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)!
    }

    // MARK: CSV

    @Test func csvContainsHeader() {
        let csv = String(data: ParentDashboardExporter.csvData(from: makeSnapshot()), encoding: .utf8)!
        // The CSV now starts with a participantId comment line followed by the
        // letter table header. Both must be present for A/B analysis consumers.
        #expect(csv.hasPrefix("# participantId="))
        #expect(csv.contains("letter,sessionCount,averageAccuracy,trend"))
    }

    @Test func csvContainsLetterRows() {
        let csv = String(data: ParentDashboardExporter.csvData(from: makeSnapshot()), encoding: .utf8)!
        #expect(csv.contains("A,2,"), "Expected A row with 2 sessions")
        #expect(csv.contains("B,1,"), "Expected B row with 1 session")
    }

    @Test func csvContainsDurationSection() {
        // Duration rows are filtered on enrolment like the phase rows
        // (review 2026-09-05); pin the fixture to "no enrolment" so the
        // test-device's own enrolledAt cannot hide the 2026-03 rows.
        let csv = String(data: ParentDashboardExporter.csvData(from: makeSnapshot(), enrolledAt: nil), encoding: .utf8)!
        #expect(csv.contains("date,recordedAt,durationSeconds,wallClockSeconds,condition,inputDevice"))
        #expect(csv.contains("2026-03-01"))
    }

    @Test func csvEmptySnapshotIsValid() {
        let csv = String(data: ParentDashboardExporter.csvData(from: DashboardSnapshot()), encoding: .utf8)!
        #expect(csv.hasPrefix("# participantId="))
        #expect(csv.contains("letter,sessionCount,averageAccuracy,trend"))
    }

    @Test func csvIncludesParticipantIdAndConditionColumns() {
        let csv = String(data: ParentDashboardExporter.csvData(
            from: makeSnapshot(),
            participantId: UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!
        ), encoding: .utf8)!
        #expect(csv.contains("# participantId=00000000-0000-0000-0000-0000000000AB"))
        #expect(csv.contains("date,recordedAt,durationSeconds,wallClockSeconds,condition,inputDevice"))
        #expect(csv.contains("letter,phase,completed,score,schedulerPriority,condition"))
    }

    // MARK: JSON

    @Test func jsonDecodesBack() throws {
        let snap = makeSnapshot()
        let data = try ParentDashboardExporter.jsonData(from: snap)
        let decoded = try JSONDecoder().decode(DashboardSnapshot.self, from: data)
        #expect(decoded.letterStats.count == snap.letterStats.count)
    }

    @Test func jsonIsPrettyPrinted() throws {
        let data = try ParentDashboardExporter.jsonData(from: makeSnapshot())
        let str = String(data: data, encoding: .utf8)!
        #expect(str.contains("\n"), "Expected pretty-printed JSON with newlines")
    }

    // MARK: File export

    @Test func exportFileURLCSVWritesFile() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let url = try ParentDashboardExporter.exportFileURL(from: makeSnapshot(), format: .csv, tempDirectory: tmp)
        #expect(url.pathExtension == "csv")
        #expect(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: url)
    }

    @Test func exportFileURLJSONWritesFile() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let url = try ParentDashboardExporter.exportFileURL(from: makeSnapshot(), format: .json, tempDirectory: tmp)
        #expect(url.pathExtension == "json")
        #expect(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: url)
    }

    @Test func exportFilenameContainsDate() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let url = try ParentDashboardExporter.exportFileURL(from: makeSnapshot(), format: .csv, tempDirectory: tmp)
        #expect(url.lastPathComponent.contains("primae_progress_"))
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Phase-row recognition + recordedAt are session-aligned

    /// When the VM passes a `RecognitionSample` to `recordPhaseSession`,
    /// the per-phase row emits the actual session-aligned values —
    /// `PhaseSessionRecord` carries the recognition fields directly.
    @Test func csvPhaseRowEmitsSessionAlignedRecognition() {
        let recordedAt = Date(timeIntervalSince1970: 1_770_000_000)
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "A", phase: "freeWrite", completed: true,
            score: 0.7, schedulerPriority: 0, condition: .threePhase,
            recordedAt: recordedAt,
            recognition: RecognitionSample(
                predictedLetter: "O", confidence: 0.62, isCorrect: false
            )
        ))
        let csv = String(data: ParentDashboardExporter.csvData(
            from: snap, progress: [:], enrolledAt: nil), encoding: .utf8)!
        let isoTs = ISO8601DateFormatter().string(from: recordedAt)
        // Phase row format: letter,phase,completed,score,prio,condition,
        // recordedAt,recognition_predicted,recognition_confidence,
        // recognition_confidence_raw,recognition_correct,
        // formAccuracy,tempoConsistency,pressureControl,rhythmScore,
        // inputDevice.
        #expect(csv.contains("A,freeWrite,true,0.7000,0.0000,threePhase,\(isoTs),O,0.6200,,false,,,,,"),
                "Expected session-aligned recognition + timestamp — found:\n\(csv)")
    }

    /// A multi-stroke letter's `strokeOrder` is comma-joined ("0,2,1" for
    /// a crossbar-first A). Unquoted, that field split a CSV row into
    /// extra columns and shifted `reversedStrokeCount`, `studyMode` and
    /// `probe` to the right — every A, F and L freeWrite row in the pilot
    /// (audit 2026-09-04, class one). The row must parse back to exactly
    /// as many fields as the header, with the order intact.
    @Test func csvQuotesCommaJoinedStrokeOrder() throws {
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "A", phase: "freeWrite", completed: true,
            score: 0.7, schedulerPriority: 0, condition: .threePhase,
            recordedAt: Date(timeIntervalSince1970: 1_770_000_000),
            spatialDeviation: 0.05, strokeCount: 3, strokeOrder: "0,2,1",
            reversedStrokeCount: 1, studyMode: true, probe: "posttest"
        ))
        let csv = String(data: ParentDashboardExporter.csvData(
            from: snap, progress: [:], enrolledAt: nil), encoding: .utf8)!
        let lines = csv.components(separatedBy: "\n")
        let headerIdx = try #require(lines.firstIndex { $0.hasPrefix("letter,phase,completed,") })
        let header = lines[headerIdx].components(separatedBy: ",")
        let row = try #require(lines.dropFirst(headerIdx + 1).first { $0.hasPrefix("A,freeWrite,") })
        let fields = Self.parseCSVRow(row)
        #expect(fields.count == header.count,
                "row has \(fields.count) fields, header \(header.count):\n\(row)")
        #expect(fields[header.firstIndex(of: "strokeOrder")!] == "0,2,1")
        #expect(fields[header.firstIndex(of: "reversedStrokeCount")!] == "1")
        #expect(fields[header.firstIndex(of: "studyMode")!] == "true")
        #expect(fields[header.firstIndex(of: "probe")!] == "posttest")
        #expect(row.contains("\"0,2,1\""), "the comma-joined field must be quoted, RFC 4180")

        // TSV: no tab in the field, so it stays unquoted and splits cleanly.
        let tsv = String(data: ParentDashboardExporter.tsvData(
            from: snap, progress: [:], enrolledAt: nil), encoding: .utf8)!
        let tsvRow = try #require(tsv.components(separatedBy: "\n").first { $0.hasPrefix("A\tfreeWrite\t") })
        let tsvFields = tsvRow.components(separatedBy: "\t")
        #expect(tsvFields.count == header.count)
        #expect(tsvFields[header.firstIndex(of: "strokeOrder")!] == "0,2,1")
    }

    /// Minimal RFC 4180 reader for one row: quoted fields may contain the
    /// separator; a doubled quote inside a quoted field is one quote.
    private static func parseCSVRow(_ row: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var it = row.makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return it.next()
        }
        while let ch = next() {
            if inQuotes {
                if ch == "\"" {
                    if let n = it.next() {
                        if n == "\"" { current.append("\"") } else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else { current.append(ch) }
            } else if ch == "\"" {
                inQuotes = true
            } else if ch == "," {
                fields.append(current); current = ""
            } else {
                current.append(ch)
            }
        }
        fields.append(current)
        return fields
    }

    /// Phase rows without a recognition sample (guided / observe / direct,
    /// or freeWrite that fired before the recogniser returned) still emit
    /// blanks for the recognition columns — but `recordedAt` is always
    /// populated for new records.
    @Test func csvPhaseRowBlankRecognitionWhenNoneRecorded() {
        let recordedAt = Date(timeIntervalSince1970: 1_770_000_000)
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "C", phase: "guided", completed: true,
            score: 0.5, schedulerPriority: 0, condition: .threePhase,
            recordedAt: recordedAt
        ))
        let csv = String(data: ParentDashboardExporter.csvData(
            from: snap, progress: [:], enrolledAt: nil), encoding: .utf8)!
        let isoTs = ISO8601DateFormatter().string(from: recordedAt)
        #expect(csv.contains("C,guided,true,0.5000,0.0000,threePhase,\(isoTs),,,,,,,,,"),
                "Expected blank recognition columns + populated recordedAt — found:\n\(csv)")
    }

    // MARK: - Pre-enrolment records are filtered

    /// Any phase-session row recorded before `ParticipantStore.enrolledAt`
    /// is dropped at export time so pilot / sandbox activity doesn't get
    /// silently attributed to the assigned thesis arm.
    @Test func csvFiltersPreEnrolmentRows() {
        let enrolledAt = Date(timeIntervalSince1970: 1_770_000_000)
        let earlier   = enrolledAt.addingTimeInterval(-86_400)
        let later     = enrolledAt.addingTimeInterval( 86_400)
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "P", phase: "guided", completed: true,
            score: 0.5, schedulerPriority: 0, condition: .threePhase,
            recordedAt: earlier
        ))
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "Q", phase: "guided", completed: true,
            score: 0.5, schedulerPriority: 0, condition: .threePhase,
            recordedAt: later
        ))
        let csv = String(data: ParentDashboardExporter.csvData(
            from: snap, progress: [:], enrolledAt: enrolledAt), encoding: .utf8)!
        #expect(csv.contains("# enrolledAt="))
        #expect(!csv.contains("P,guided,true"),
                "Pre-enrolment row must be discarded — found:\n\(csv)")
        #expect(csv.contains("Q,guided,true"),
                "Post-enrolment row must survive — found:\n\(csv)")
    }

    /// Legacy rows missing `recordedAt` are filtered when an `enrolledAt`
    /// exists — we can't prove they're post-enrolment, and the decoder
    /// defaulted their condition to `.threePhase`, which would silently
    /// inflate that arm. When no `enrolledAt` is set (study not yet
    /// started), they survive so pre-thesis dev/test data still appears
    /// in dev exports.
    @Test func csvFiltersLegacyRowsWithoutRecordedAtWhenEnrolled() {
        let enrolledAt = Date(timeIntervalSince1970: 1_770_000_000)
        var snap = DashboardSnapshot()
        // Decoding a record from a JSON file without `recordedAt`
        // produces nil there. Construct one manually via JSON to mirror
        // the legacy wire format.
        let legacyJSON = """
        {
          "letter": "L", "phase": "guided", "completed": true,
          "score": 0.5, "schedulerPriority": 0.0, "condition": "threePhase"
        }
        """.data(using: .utf8)!
        let legacy = try! JSONDecoder().decode(PhaseSessionRecord.self, from: legacyJSON)
        snap.phaseSessionRecords.append(legacy)
        // With enrolledAt set: legacy row is dropped.
        let csvEnrolled = String(data: ParentDashboardExporter.csvData(
            from: snap, progress: [:], enrolledAt: enrolledAt), encoding: .utf8)!
        #expect(!csvEnrolled.contains("L,guided,true"),
                "Legacy row without recordedAt must be filtered when enrolledAt is set — found:\n\(csvEnrolled)")
        // Without enrolledAt: dev exports still see legacy rows.
        let csvDev = String(data: ParentDashboardExporter.csvData(
            from: snap, progress: [:], enrolledAt: nil), encoding: .utf8)!
        #expect(csvDev.contains("L,guided,true"),
                "Legacy row must survive in dev exports (enrolledAt: nil) — found:\n\(csvDev)")
    }

    // MARK: - speedTrend column on letter-aggregate rows

    @Test func csvLetterAggregateContainsSpeedTrend() {
        var snap = DashboardSnapshot()
        snap.letterStats["A"] = LetterAccuracyStat(letter: "A", accuracySamples: [0.8])
        var prog = LetterProgress()
        prog.speedTrend = [1.2, 1.5, 1.8]
        let csv = String(data: ParentDashboardExporter.csvData(
            from: snap, progress: ["A": prog], enrolledAt: nil), encoding: .utf8)!
        #expect(csv.contains("speedTrend"),
                "Expected speedTrend column header")
        #expect(csv.contains("1.2000;1.5000;1.8000"),
                "Expected semicolon-joined speedTrend values — found:\n\(csv)")
    }
}
