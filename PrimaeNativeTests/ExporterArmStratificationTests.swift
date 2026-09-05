// Golden coverage for the CSV export's arm-stratified metric section.
//
// Audit finding 22: `letterByArm`, `letterByAudioArm`,
// `averageFreeWriteScore_*`, `schedulerEffectivenessProxy_*` and
// `phaseCompletionRate_*` had ZERO test coverage — a refactor could
// drop a whole row family and CI would stay green. The pre-existing
// `ParentDashboardExporterTests` are `csv.contains(…)` spot-checks,
// which is precisely how the gap survived: a substring probe passes
// as long as *something* resembling the row appears anywhere.
//
// This suite parses the metric section into structured rows and
// asserts arity, domain, and the exact expected row set. A dropped
// family, a renamed column, a lost field, or a mis-keyed grouping all
// fail here.
//
// FIXTURE DESIGN — the thesis axis and the audio axis are deliberately
// DECORRELATED. Letter A's three completed freeWrite records sit in one
// thesis arm (`threePhase`) but split across two audio arms (2 phoneme,
// 1 spatial). If a refactor collapsed the twin blocks onto a single key
// path, `letterByAudioArm` would report A once with n=3 instead of
// twice with n=2 and n=1, and `armsAreKeyedIndependently` fails.

import Testing
import Foundation
@testable import PrimaeNative

@Suite struct ExporterArmStratificationTests {

    // MARK: - Fixture

    /// Stable id so the suite never reads `ParticipantStore` (and so
    /// cannot be perturbed by another suite's UserDefaults writes).
    private let pid = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    /// Five records. Completed freeWrite scores per axis:
    ///   thesis  threePhase → A: 0.2, 0.6, 0.7      guidedOnly → B: 1.0
    ///   audio   phoneme    → A: 0.2, 0.6           spatial    → A: 0.7
    ///                                              silent     → B: 1.0
    /// The trailing incomplete `guided` row exercises the completion-rate
    /// denominator without entering any completed-only aggregate.
    private func snapshot() -> DashboardSnapshot {
        var s = DashboardSnapshot()
        s.phaseSessionRecords = [
            PhaseSessionRecord(letter: "A", phase: "freeWrite", completed: true,
                               score: 0.2, schedulerPriority: 0.1,
                               condition: .threePhase, audioCondition: .phoneme),
            PhaseSessionRecord(letter: "A", phase: "freeWrite", completed: true,
                               score: 0.6, schedulerPriority: 0.5,
                               condition: .threePhase, audioCondition: .phoneme),
            PhaseSessionRecord(letter: "A", phase: "freeWrite", completed: true,
                               score: 0.7, schedulerPriority: 0.9,
                               condition: .threePhase, audioCondition: .spatial),
            PhaseSessionRecord(letter: "B", phase: "freeWrite", completed: true,
                               score: 1.0, schedulerPriority: 0.2,
                               condition: .guidedOnly, audioCondition: .silent),
            PhaseSessionRecord(letter: "A", phase: "guided", completed: false,
                               score: 0.0, schedulerPriority: 0.0,
                               condition: .threePhase, audioCondition: .phoneme),
        ]
        return s
    }

    /// `enrolledAt: nil` so the per-phase pre-enrolment filter is inert
    /// and the fixture reaches the aggregates unmodified.
    private func csv() -> [String] {
        let data = ParentDashboardExporter.csvData(
            from: snapshot(), participantId: pid, progress: [:], enrolledAt: nil)
        return String(data: data, encoding: .utf8)!
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    // MARK: - Section parsing
    //
    // The metric section is headed `metric,value`, but the two
    // `letterBy*` families are 5-column rows emitted INSIDE it with no
    // separating blank line. Parsing therefore splits on arity rather
    // than on section boundaries.

    /// Two-field `key,value` rows from the metric section.
    private func metrics(_ lines: [String]) -> [String: String] {
        guard let start = lines.firstIndex(of: "metric,value") else { return [:] }
        var out: [String: String] = [:]
        for line in lines[(start + 1)...] where !line.isEmpty {
            let f = line.components(separatedBy: ",")
            if f.count == 2 { out[f[0]] = f[1] }
        }
        return out
    }

    /// Rows of one `letterBy*` family, excluding its header.
    private func family(_ name: String, in lines: [String]) -> [[String]] {
        lines.filter { $0.hasPrefix("\(name),") }
             .map { $0.components(separatedBy: ",") }
             .filter { $0.count > 1 && $0[1] != "letter" }
    }

    private func header(_ name: String, in lines: [String]) -> [String]? {
        lines.first { $0.hasPrefix("\(name),letter,") }?.components(separatedBy: ",")
    }

    // MARK: - 1. phaseCompletionRate_*

    @Test("phaseCompletionRate_ rows exist per observed phase, and only per observed phase")
    func phaseCompletionRates() throws {
        let m = metrics(csv())

        let freeWrite = try #require(m["phaseCompletionRate_freeWrite"],
            "freeWrite completion-rate row is missing from the metric section")
        let guided = try #require(m["phaseCompletionRate_guided"],
            "guided completion-rate row is missing from the metric section")

        // 4 of 4 freeWrite records completed; 0 of 1 guided completed.
        #expect(Double(freeWrite) == 1.0, "expected 1.0000, got \(freeWrite)")
        #expect(Double(guided) == 0.0, "expected 0.0000, got \(guided)")

        // Phases with no records must not emit a row at all — a defaulted
        // 0.0 would read as "the child never completed observe".
        #expect(m["phaseCompletionRate_observe"] == nil)
        #expect(m["phaseCompletionRate_direct"] == nil)

        // Well-formed: 4 decimal places, parseable, in [0,1].
        for (k, v) in m where k.hasPrefix("phaseCompletionRate_") {
            let d = try #require(Double(v), "\(k) value '\(v)' does not parse")
            #expect((0...1).contains(d), "\(k) out of domain: \(d)")
            #expect(v.split(separator: ".").last?.count == 4,
                    "\(k) should carry 4 decimals, got '\(v)'")
        }
    }

    // MARK: - 2. averageFreeWriteScore_<thesisArm>

    @Test("averageFreeWriteScore_ is emitted per populated thesis arm and omitted for empty ones")
    func averageFreeWriteScorePerThesisArm() throws {
        let m = metrics(csv())

        let three = try #require(m["averageFreeWriteScore_threePhase"],
            "threePhase arm aggregate is missing")
        let guidedOnly = try #require(m["averageFreeWriteScore_guidedOnly"],
            "guidedOnly arm aggregate is missing")

        #expect(Double(three) == 0.5, "(0.2+0.6+0.7)/3 = 0.5, got \(three)")
        #expect(Double(guidedOnly) == 1.0, "single 1.0 record, got \(guidedOnly)")

        // `control` has no records: the block guards on !freeWrite.isEmpty,
        // so an absent row is correct and a 0.0000 row would be a bug.
        #expect(m["averageFreeWriteScore_control"] == nil,
                "empty arm must be omitted, not emitted as 0")

        // The unsuffixed global aggregate stays independent of the split.
        let global = try #require(m["averageFreeWriteScore"])
        #expect(Double(global) == 0.625, "(0.2+0.6+0.7+1.0)/4 = 0.625, got \(global)")
    }

    // MARK: - 3. averageFreeWriteScore_audio_<audioArm>

    @Test("averageFreeWriteScore_audio_ is emitted per populated audio arm")
    func averageFreeWriteScorePerAudioArm() throws {
        let m = metrics(csv())

        let phoneme = try #require(m["averageFreeWriteScore_audio_phoneme"],
            "phoneme arm aggregate is missing — the pilot's primary IV")
        let spatial = try #require(m["averageFreeWriteScore_audio_spatial"],
            "spatial arm aggregate is missing")
        let silent = try #require(m["averageFreeWriteScore_audio_silent"],
            "silent arm aggregate is missing")

        #expect(Double(phoneme) == 0.4, "(0.2+0.6)/2 = 0.4, got \(phoneme)")
        #expect(Double(spatial) == 0.7, "single 0.7 record, got \(spatial)")
        #expect(Double(silent) == 1.0, "single 1.0 record, got \(silent)")

        // All three arms of the PRIMARY axis must be present whenever
        // populated — a silently dropped arm is an unanalysable pilot.
        for arm in PilotAudioCondition.allCases {
            #expect(m["averageFreeWriteScore_audio_\(arm.rawValue)"] != nil,
                    "audio arm '\(arm.rawValue)' vanished from the export")
        }
    }

    // MARK: - 4. schedulerEffectivenessProxy_<thesisArm>

    @Test("schedulerEffectivenessProxy_ is emitted per arm with ≥2 usable pairs")
    func schedulerProxyPerArm() throws {
        let m = metrics(csv())

        // threePhase: letter A has 3 completed records → 2 pairs.
        //   pairs = (prio 0.1, Δ +0.4), (prio 0.5, Δ −0.1)
        //   two points, opposite signs → r = −1 exactly.
        let proxy = try #require(m["schedulerEffectivenessProxy_threePhase"],
            "threePhase scheduler proxy is missing")
        let r = try #require(Double(proxy), "proxy '\(proxy)' does not parse")
        #expect((-1.0...1.0).contains(r), "Pearson r out of domain: \(r)")
        #expect(abs(r - (-1.0)) < 0.0001, "expected r ≈ -1.0, got \(r)")

        // guidedOnly has one record for B → 0 pairs → row correctly absent.
        #expect(m["schedulerEffectivenessProxy_guidedOnly"] == nil,
                "an arm with <2 pairs must be omitted, not emitted as 0")
        #expect(m["schedulerEffectivenessProxy_control"] == nil)
    }

    // D11#2 regression, exporter side: the per-arm proxy's `chrono` local
    // used to be array (insertion) order, not `recordedAt` order. The
    // fixture above happens to insert already in chronological order, so
    // it can't tell the two apart — this one deliberately doesn't.
    @Test("schedulerEffectivenessProxy_ is independent of record insertion order")
    func schedulerProxyPerArm_insertionOrderIndependent() throws {
        func snap(_ records: [PhaseSessionRecord]) -> DashboardSnapshot {
            var s = DashboardSnapshot()
            s.phaseSessionRecords = records
            return s
        }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let chronological = [
            PhaseSessionRecord(letter: "A", phase: "freeWrite", completed: true,
                                score: 0.2, schedulerPriority: 0.1,
                                condition: .threePhase, recordedAt: base),
            PhaseSessionRecord(letter: "A", phase: "freeWrite", completed: true,
                                score: 0.6, schedulerPriority: 0.5,
                                condition: .threePhase, recordedAt: base.addingTimeInterval(60)),
            PhaseSessionRecord(letter: "A", phase: "freeWrite", completed: true,
                                score: 0.5, schedulerPriority: 0.9,
                                condition: .threePhase, recordedAt: base.addingTimeInterval(120)),
        ]
        let chronoCSV = ParentDashboardExporter.csvData(
            from: snap(chronological), participantId: pid, progress: [:], enrolledAt: nil)
        let reversedCSV = ParentDashboardExporter.csvData(
            from: snap(chronological.reversed()), participantId: pid, progress: [:], enrolledAt: nil)

        func proxy(_ data: Data) throws -> Double {
            let lines = String(data: data, encoding: .utf8)!.split(separator: "\n").map(String.init)
            let m = metrics(lines)
            let raw = try #require(m["schedulerEffectivenessProxy_threePhase"])
            return try #require(Double(raw))
        }
        #expect(abs(try proxy(chronoCSV) - (try proxy(reversedCSV))) < 1e-9,
                "the per-arm proxy must be keyed on recordedAt, not insertion order")
    }

    // MARK: - 5. letterByArm

    @Test("letterByArm carries its header and one well-formed row per (arm, letter)")
    func letterByArmRows() throws {
        let lines = csv()

        let head = try #require(header("letterByArm", in: lines),
            "letterByArm header row is missing entirely")
        #expect(head == ["letterByArm", "letter", "arm", "sampleCount", "averageScore"],
                "header columns changed: \(head)")

        let rows = family("letterByArm", in: lines)
        #expect(rows.count == 2, "expected 2 (arm, letter) rows, got \(rows.count): \(rows)")

        // Grouping is over ALL completed records, not freeWrite only.
        let flat = Set(rows.map { $0.joined(separator: ",") })
        #expect(flat == [
            "letterByArm,A,threePhase,3,0.5000",
            "letterByArm,B,guidedOnly,1,1.0000",
        ], "row set mismatch: \(flat.sorted())")

        try assertWellFormed(rows, family: "letterByArm", arity: head.count)
    }

    // MARK: - 6. letterByAudioArm

    @Test("letterByAudioArm carries its header and one well-formed row per (audioArm, letter)")
    func letterByAudioArmRows() throws {
        let lines = csv()

        let head = try #require(header("letterByAudioArm", in: lines),
            "letterByAudioArm header row is missing entirely")
        #expect(head == ["letterByAudioArm", "letter", "audioArm", "sampleCount", "averageScore"],
                "header columns changed: \(head)")

        let rows = family("letterByAudioArm", in: lines)
        #expect(rows.count == 3, "expected 3 (audioArm, letter) rows, got \(rows.count): \(rows)")

        let flat = Set(rows.map { $0.joined(separator: ",") })
        #expect(flat == [
            "letterByAudioArm,A,phoneme,2,0.4000",
            "letterByAudioArm,A,spatial,1,0.7000",
            "letterByAudioArm,B,silent,1,1.0000",
        ], "row set mismatch: \(flat.sorted())")

        try assertWellFormed(rows, family: "letterByAudioArm", arity: head.count)
    }

    // MARK: - 7. The two axes are keyed independently

    @Test("the thesis axis and the audio axis are not collapsed onto one key path")
    func armsAreKeyedIndependently() throws {
        let lines = csv()
        let byArm = family("letterByArm", in: lines)
        let byAudio = family("letterByAudioArm", in: lines)

        // Letter A is one thesis arm but two audio arms. Any refactor
        // that reuses `\.condition` for both blocks makes these equal.
        let aThesis = byArm.filter { $0[1] == "A" }
        let aAudio = byAudio.filter { $0[1] == "A" }
        #expect(aThesis.count == 1, "A should occupy one thesis arm, got \(aThesis)")
        #expect(aAudio.count == 2, "A should split across two audio arms, got \(aAudio)")

        // …and the sample counts must differ accordingly (3 vs 2+1).
        #expect(aThesis.first?[3] == "3")
        #expect(Set(aAudio.map { $0[3] }) == ["2", "1"])

        // Arm labels must come from the right enum.
        let thesisLabels = Set(byArm.map { $0[2] })
        let audioLabels = Set(byAudio.map { $0[2] })
        #expect(thesisLabels.isSubset(of: Set(ThesisCondition.allCases.map(\.rawValue))),
                "letterByArm carries non-thesis labels: \(thesisLabels)")
        #expect(audioLabels.isSubset(of: Set(PilotAudioCondition.allCases.map(\.rawValue))),
                "letterByAudioArm carries non-audio labels: \(audioLabels)")
        #expect(thesisLabels.isDisjoint(with: audioLabels),
                "the two axes share a label — they are not independent: \(thesisLabels) / \(audioLabels)")
    }

    // MARK: - 8. Pre-enrolment rows never reach an arm-split aggregate
    //
    // D11#1: the pre-enrolment filter ran only over the raw per-phase
    // rows; every arm-split aggregate below read `snapshot.phaseSessionRecords`
    // directly and unfiltered, so a pre-enrolment row (proctor
    // test-taps, sandbox activity) was excluded from the CSV's row-level
    // section but still corrupted the between-arm comparison — the exact
    // attribution the filter exists to prevent.

    @Test("a pre-enrolment record does not reach any arm-split aggregate")
    func preEnrolmentRowsExcludedFromArmAggregates() throws {
        let enrolledAt = Date(timeIntervalSince1970: 1_000_000)
        var s = snapshot()
        // Same arm (guidedOnly/silent) as the existing single B record
        // (score 1.0), so leakage is visible as both a moved average and
        // an inflated sample count.
        s.phaseSessionRecords.append(
            PhaseSessionRecord(letter: "B", phase: "freeWrite", completed: true,
                               score: 0.0, schedulerPriority: 0.0,
                               condition: .guidedOnly, audioCondition: .silent,
                               recordedAt: enrolledAt.addingTimeInterval(-3600)))

        let data = ParentDashboardExporter.csvData(
            from: s, participantId: pid, progress: [:], enrolledAt: enrolledAt)
        let lines = String(data: data, encoding: .utf8)!
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let m = metrics(lines)

        let thesisArm = try #require(m["averageFreeWriteScore_guidedOnly"])
        #expect(Double(thesisArm) == 1.0,
                "pre-enrolment score 0.0 pulled the guidedOnly average down: got \(thesisArm)")
        let audioArm = try #require(m["averageFreeWriteScore_audio_silent"])
        #expect(Double(audioArm) == 1.0,
                "pre-enrolment score 0.0 pulled the silent-arm average down: got \(audioArm)")

        let byArmRow = try #require(family("letterByArm", in: lines)
            .first { $0[1] == "B" && $0[2] == "guidedOnly" })
        #expect(byArmRow[3] == "1",
                "pre-enrolment record inflated letterByArm's sample count: \(byArmRow)")
        let byAudioRow = try #require(family("letterByAudioArm", in: lines)
            .first { $0[1] == "B" && $0[2] == "silent" })
        #expect(byAudioRow[3] == "1",
                "pre-enrolment record inflated letterByAudioArm's sample count: \(byAudioRow)")
    }

    // MARK: - 9. Pre-enrolment rows never reach the HEADLINE aggregates either
    //
    // D11#1's second half (2026-09-04): `phaseCompletionRate_*`,
    // `averageFreeWriteScore`, `schedulerEffectivenessProxy` and the four
    // Schreibmotorik averages are computed properties of the snapshot and
    // ran over every record on disk — the filter never reached them, even
    // after the ticket was marked closed.

    @Test("a pre-enrolment record does not reach phaseCompletionRate, averageFreeWriteScore or the Schreibmotorik averages")
    func preEnrolmentRowsExcludedFromHeadlineAggregates() throws {
        let enrolledAt = Date(timeIntervalSince1970: 1_000_000)
        let enrolled = PhaseSessionRecord(
            letter: "B", phase: "freeWrite", completed: true,
            score: 1.0, schedulerPriority: 0.0,
            condition: .threePhase, audioCondition: .phoneme,
            recordedAt: enrolledAt.addingTimeInterval(60),
            assessment: WritingAssessment(formAccuracy: 1, tempoConsistency: 1,
                                          pressureControl: 1, rhythmScore: 1))
        // A pre-enrolment freeWrite row at 0.0 on every scale, and a
        // pre-enrolment observe row — the only observe row in the
        // snapshot, so its completion-rate key must not appear at all.
        let strayFreeWrite = PhaseSessionRecord(
            letter: "B", phase: "freeWrite", completed: true,
            score: 0.0, schedulerPriority: 0.0,
            condition: .threePhase, audioCondition: .phoneme,
            recordedAt: enrolledAt.addingTimeInterval(-1800),
            assessment: WritingAssessment(formAccuracy: 0, tempoConsistency: 0,
                                          pressureControl: 0, rhythmScore: 0))
        let strayObserve = PhaseSessionRecord(
            letter: "B", phase: "observe", completed: true,
            score: 1.0, schedulerPriority: 0.0,
            condition: .threePhase, audioCondition: .phoneme,
            recordedAt: enrolledAt.addingTimeInterval(-3600))
        let s = DashboardSnapshot(phaseSessionRecords: [strayObserve, strayFreeWrite, enrolled])

        let data = ParentDashboardExporter.csvData(
            from: s, participantId: pid, progress: [:], enrolledAt: enrolledAt)
        let lines = String(data: data, encoding: .utf8)!
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let m = metrics(lines)

        #expect(m["phaseCompletionRate_observe"] == nil,
                "a phase completed only by pre-enrolment rows must not appear: \(m["phaseCompletionRate_observe"] ?? "nil")")
        #expect(m["averageFreeWriteScore"].flatMap(Double.init) == 1.0,
                "pre-enrolment freeWrite score 0.0 leaked into the headline average: \(m["averageFreeWriteScore"] ?? "nil")")
        #expect(m["averageFormAccuracy"].flatMap(Double.init) == 1.0,
                "pre-enrolment form 0.0 leaked into averageFormAccuracy: \(m["averageFormAccuracy"] ?? "nil")")
        #expect(m["averageRhythmScore"].flatMap(Double.init) == 1.0,
                "pre-enrolment rhythm 0.0 leaked into averageRhythmScore: \(m["averageRhythmScore"] ?? "nil")")
    }

    // MARK: - Shared well-formedness

    /// Arity, integer sample count, and a score inside [0,1] with the
    /// export's fixed 4-decimal format. Catches a dropped column or a
    /// field emitted in the wrong slot, which a substring probe cannot.
    private func assertWellFormed(_ rows: [[String]],
                                  family: String,
                                  arity: Int) throws {
        for row in rows {
            #expect(row.count == arity,
                    "\(family) row has \(row.count) fields, header has \(arity): \(row)")
            let n = try #require(Int(row[3]), "\(family) sampleCount '\(row[3])' is not an Int")
            #expect(n > 0, "\(family) sampleCount must be positive, got \(n)")
            let avg = try #require(Double(row[4]), "\(family) averageScore '\(row[4])' does not parse")
            #expect((0...1).contains(avg), "\(family) averageScore out of domain: \(avg)")
            #expect(row[4].split(separator: ".").last?.count == 4,
                    "\(family) averageScore should carry 4 decimals, got '\(row[4])'")
            #expect(!row[1].isEmpty, "\(family) letter field is empty")
            #expect(!row[2].isEmpty, "\(family) arm field is empty")
        }
    }

    // MARK: - 6. letterBy* families read freeWrite rows only (audit 2026-09-04)

    /// observe/direct rows carry a constant score of 1.0 and guided
    /// carries coverage; averaging them into `letterByArm` floored the
    /// per-arm accuracy near 0.5 and compared the arms on a completion
    /// counter. Only the freeWrite production row is an accuracy.
    @Test("letterByArm and letterByAudioArm ignore completed non-freeWrite rows")
    func letterByArmFamiliesAreFreeWriteOnly() throws {
        var snap = DashboardSnapshot()
        let t = Date(timeIntervalSince1970: 1_770_000_000)
        snap.phaseSessionRecords = [
            PhaseSessionRecord(letter: "A", phase: "observe", completed: true, score: 1.0,
                               schedulerPriority: 0, condition: .threePhase, audioCondition: .spatial, recordedAt: t),
            PhaseSessionRecord(letter: "A", phase: "direct", completed: true, score: 1.0,
                               schedulerPriority: 0, condition: .threePhase, audioCondition: .spatial, recordedAt: t),
            PhaseSessionRecord(letter: "A", phase: "guided", completed: true, score: 0.9,
                               schedulerPriority: 0, condition: .threePhase, audioCondition: .spatial, recordedAt: t),
            PhaseSessionRecord(letter: "A", phase: "freeWrite", completed: true, score: 0.3,
                               schedulerPriority: 0, condition: .threePhase, audioCondition: .spatial, recordedAt: t),
        ]
        let lines = String(data: ParentDashboardExporter.csvData(
            from: snap, progress: [:], enrolledAt: nil), encoding: .utf8)!
            .components(separatedBy: "\n")
        let byArm = family("letterByArm", in: lines)
        #expect(byArm == [["letterByArm", "A", "threePhase", "1", "0.3000"]],
                "one freeWrite row, its own score — got \(byArm)")
        let byAudio = family("letterByAudioArm", in: lines)
        #expect(byAudio == [["letterByAudioArm", "A", "spatial", "1", "0.3000"]],
                "got \(byAudio)")
    }

    /// The proxy pairs consecutive rows per letter. Within one pass those
    /// are observe → direct → guided → freeWrite — three different
    /// instruments — so a guided row must not form a "learning delta"
    /// with the freeWrite row that follows it (audit 2026-09-04).
    @Test("schedulerEffectivenessProxy_ pairs freeWrite rows only")
    func proxyIgnoresNonFreeWriteRows() throws {
        let t0 = Date(timeIntervalSince1970: 1_770_000_000)
        func fw(_ score: Double, _ prio: Double, _ offset: Double) -> PhaseSessionRecord {
            PhaseSessionRecord(letter: "A", phase: "freeWrite", completed: true, score: score,
                               schedulerPriority: prio, condition: .threePhase, recordedAt: t0.addingTimeInterval(offset))
        }
        func guided(_ offset: Double) -> PhaseSessionRecord {
            PhaseSessionRecord(letter: "A", phase: "guided", completed: true, score: 1.0,
                               schedulerPriority: 0.9, condition: .threePhase, recordedAt: t0.addingTimeInterval(offset))
        }
        // Three passes: the guided rows interleave with the freeWrite rows.
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords = [guided(0), fw(0.2, 0.1, 1), guided(2), fw(0.6, 0.5, 3), guided(4), fw(0.7, 0.9, 5)]
        let lines = String(data: ParentDashboardExporter.csvData(
            from: snap, progress: [:], enrolledAt: nil), encoding: .utf8)!
            .components(separatedBy: "\n")
        let r = try #require(Double(try #require(metrics(lines)["schedulerEffectivenessProxy_threePhase"])))
        // freeWrite-only pairs: (0.1, +0.4), (0.5, +0.1) → r = -1 exactly.
        // With the guided rows paired in, the deltas alternate sign and r moves.
        #expect(abs(r - (-1.0)) < 1e-6, "expected r = -1 from the two freeWrite pairs, got \(r)")
        #expect(abs(snap.schedulerEffectivenessProxy - (-1.0)) < 1e-6,
                "the store's own proxy must agree with the exporter: \(snap.schedulerEffectivenessProxy)")
    }

}
