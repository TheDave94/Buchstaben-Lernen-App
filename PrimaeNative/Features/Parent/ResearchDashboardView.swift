// ResearchDashboardView.swift
// PrimaeNative
//
// Researcher-only dashboard behind the parental gate. Surfaces every
// numeric metric the data model captures: Schreibmotorik dimensions,
// recognition predictions, condition assignments, scheduler proxy.

import SwiftUI
import AVFoundation

struct ResearchDashboardView: View {
    @Environment(TracingViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    @State private var showClearCalibrationConfirm = false
    /// Live headphone-route check for the spatial arm (read-only session
    /// query — never touches AudioEngine). Refreshed on route changes.
    @State private var headphonesConnected = ResearchDashboardView.headphoneRouteActive()
    /// New-participant flow: export-then-wipe. The share URL drives the
    /// export sheet; on its dismiss the destructive wipe confirm appears.
    @State private var newParticipantShareURL: URL?
    @State private var showNewParticipantConfirm = false
    @State private var showRelaunchAlert = false
    /// Proctor-facing studyMode as STORED, which is not necessarily what
    /// this session is running. See `studyDeviceSection`.
    @State private var studyModePending = StudyBuild.resolveStudyMode()
    @State private var showExportError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                participantHeader
                // Spatial-arm validity guard: stereo pan is void on the
                // iPad speakers, so a speaker-run spatial session is
                // invalid data. Researcher-facing only (parent-gated).
                if vm.audioCondition == .spatial && !headphonesConnected {
                    headphoneWarning
                }
                schreibmotorikSection
                recognitionSection
                conditionSection
                if vm.studyMode {
                    postTestSection
                }
                schedulerSection
                phaseRecordsSection
                letterTableSection
                phonemeCoverageSection
                studyDeviceSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .navigationTitle("Forschungs-Daten")
        .onReceive(NotificationCenter.default
            .publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)) { _ in
            headphonesConnected = Self.headphoneRouteActive()
        }
    }

    // MARK: - Headphone route (spatial arm)

    /// Whether the active output route is headphone-class (wired,
    /// Bluetooth, USB). The spatial arm's stereo-pan axis requires it.
    private static func headphoneRouteActive() -> Bool {
        let headphonePorts: Set<AVAudioSession.Port> = [
            .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio
        ]
        return AVAudioSession.sharedInstance().currentRoute.outputs
            .contains { headphonePorts.contains($0.portType) }
    }

    private var headphoneWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Keine Kopfhörer verbunden", systemImage: "exclamationmark.triangle.fill")
                .font(.body(FontSize.md, weight: .semibold))
                .foregroundStyle(.red)
            Text("Dieses Gerät ist dem Raumklang-Arm zugeordnet. Ohne Kopfhörer ist das Stereo-Panning (horizontale Stiftposition → links/rechts) über die iPad-Lautsprecher wirkungslos — eine so durchgeführte Session ist ungültige Studien-Daten. Vor der Session Kopfhörer verbinden.")
                .font(.caption)
                .foregroundStyle(Color.inkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Participant header

    private var participantHeader: some View {
        // Short ID + the ACTIVE session arms (read live from the VM, not
        // the last record) so a proctor glancing at the device during
        // handoff can confirm which participant is enrolled — the
        // anti-data-merge safeguard. Research-tab only (parent-gated);
        // never surfaced child-facing. After a "Neuer Teilnehmer" reset
        // the arms reflect the running session until the app is
        // relaunched (see the relaunch prompt).
        let shortID = ParticipantStore.participantId.uuidString.prefix(8)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Aktiver Teilnehmer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.inkSoft)
            Text("Teilnehmer \(String(shortID))")
                .font(.system(.title2, design: .monospaced).weight(.bold))
                .textSelection(.enabled)
            Text("\(vm.audioCondition.displayName) · \(vm.thesisCondition.displayName)")
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.inkSoft)
            // Third axis, for proctor handoff checks: which 3 of the 5
            // study letters this participant trains.
            Text("Trainiert: \(vm.trainedSubset.displayName)")
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.inkSoft)
            Text(ParticipantStore.participantId.uuidString)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.inkSoft)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Study device prep

    /// Researcher control to wipe on-device stroke calibrations before a
    /// pilot session. Pilot iPads are used devices that may carry
    /// Druckschrift overrides; clearing them (together with `studyMode`)
    /// makes every child trace the identical frozen bundle stimulus.
    /// Surfaces `clearAllCalibrations()` — previously reachable only via
    /// the debug calibrator overlay — and mirrors that overlay's
    /// destructive-confirm pattern. Scoped, like the overlay, to the
    /// active `SchriftArt` (the pilot runs Druckschrift).
    private var studyDeviceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Studien-Gerät vorbereiten",
                          subtitle: "Studienmodus aktivieren und gespeicherte Kalibrierungen entfernen, damit jedes Kind exakt das gebündelte Stimulus-Set nachspurt")
            // Writes the STORED value only — never `vm.studyMode` on the
            // live session. Most of what studyMode means is captured at
            // `TracingViewModel.init`: the null haptic/speech/prompt
            // engines, the fixed adaptation policy, the pinned SchriftArt
            // and letter ordering. Only the rest (stimulus resolution,
            // practice pool, retry and post-trial feedback suppression)
            // reads the live property. Binding the toggle straight to it
            // therefore produced a session that filtered letters and
            // stripped feedback while still firing haptics and TTS with
            // an unpinned SchriftArt — invalid study data that looked
            // correct from the toggle. The three sibling research
            // controls in SettingsView already say "wirksam beim
            // nächsten App-Start"; this one now behaves that way too.
            Toggle(isOn: Binding(
                get: { studyModePending },
                set: {
                    studyModePending = $0
                    UserDefaults.standard.set($0, forKey: StudyBuild.studyModeDefaultsKey)
                })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Studienmodus")
                        .font(.body(FontSize.md, weight: .semibold))
                    Text(studyModePending
                         ? "An — dieses Gerät spurt exakt das gebündelte Stimulus-Set nach; gespeicherte Kalibrierungs-Overrides werden umgangen."
                         : "Aus — normale Kalibrierung; gespeicherte Overrides gewinnen.")
                        .font(.caption)
                        .foregroundStyle(Color.inkSoft)
                    if studyModePending != vm.studyMode {
                        Label(
                            "Wirksam beim nächsten App-Start. Diese Sitzung läuft weiter mit Studienmodus \(vm.studyMode ? "An" : "Aus") — App vor der Session vollständig schließen und neu starten.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }
            .accessibilityHint("Nur für Studienleitung. Legt fest, ob dieses Gerät exakt das gebündelte Stimulus-Set nachspurt und sämtliches Feedback stummgeschaltet wird. Änderung wird beim nächsten App-Start wirksam.")
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 8))

            Divider().padding(.vertical, 2)
            Text("Neuen Teilnehmer beginnen")
                .font(.body(FontSize.md, weight: .semibold))
            Text("Exportiert zuerst die aktuellen Daten (JSON-Archiv), dann werden alle Teilnehmer-Daten gelöscht und ein neuer Teilnehmer mit neuer ID und neuer Studienarm-Zuordnung angelegt. Geräte-Einstellungen bleiben erhalten.")
                .font(.caption)
                .foregroundStyle(Color.inkSoft)
            Button {
                do {
                    newParticipantShareURL = try ParentDashboardExporter.exportFileURL(
                        from: vm.dashboardSnapshot,
                        format: .json,
                        progress: vm.allProgress,
                        // The pre-wipe archive MUST carry the traces too —
                        // otherwise the saved records' rawTraceIDs dangle
                        // after rawTraceStore.reset() wipes the traces.
                        rawTraces: vm.rawTraces)
                } catch {
                    showExportError = true
                }
            } label: {
                Label("Neuer Teilnehmer", systemImage: "person.crop.circle.badge.plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)

            Divider().padding(.vertical, 2)
            Button(role: .destructive) {
                showClearCalibrationConfirm = true
            } label: {
                Label("Kalibrierungs-Overrides löschen", systemImage: "trash")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .confirmationDialog("Kalibrierungs-Overrides löschen?",
                                isPresented: $showClearCalibrationConfirm,
                                titleVisibility: .visible) {
                Button("Löschen", role: .destructive) { vm.clearAllCalibrations() }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Entfernt jede auf diesem Gerät gespeicherte Stroke-Kalibrierung für die aktive Schriftart. Das gebündelte Set übernimmt anschließend. Für Studien-Geräte vor dem Piloten empfohlen.")
            }
        }
        // Export the outgoing participant's data first; the wipe confirm
        // only appears AFTER this sheet dismisses — export strictly
        // precedes any destructive action.
        .sheet(isPresented: Binding(
            get: { newParticipantShareURL != nil },
            set: { if !$0 { newParticipantShareURL = nil } }
        ), onDismiss: {
            showNewParticipantConfirm = true
        }) {
            if let url = newParticipantShareURL {
                ActivitySheet(items: [url])
            }
        }
        .confirmationDialog("Teilnehmer-Daten löschen?",
                            isPresented: $showNewParticipantConfirm,
                            titleVisibility: .visible) {
            Button("Löschen & neu starten", role: .destructive) {
                vm.resetForNewParticipant()
                showRelaunchAlert = true
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Daten exportiert? Diese Aktion löscht unwiderruflich alle Teilnehmer-Daten (Fortschritt, Sessions, Sterne, Kalibrierungen) und legt einen neuen Teilnehmer mit neuer ID und neuer Studienarm-Zuordnung an. Geräte-Einstellungen bleiben erhalten.")
        }
        .alert("Neustart erforderlich", isPresented: $showRelaunchAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Neuer Teilnehmer angelegt. Bitte die App jetzt vollständig schließen und neu starten, damit die neue Studienarm-Zuordnung aktiv wird.")
        }
        .alert("Export fehlgeschlagen", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Die Export-Datei konnte nicht erstellt werden. Es wurde nichts gelöscht.")
        }
    }

    // MARK: - Phoneme coverage (phoneme-arm pilot-readiness check)

    /// Before-the-fact surface for the H5/P6 gap: which loaded letters
    /// will degrade to name audio in the phoneme arm because they carry
    /// no phoneme recording. The gap is static (a property of the bundle),
    /// so this is computed on-demand from the already-loaded assets —
    /// `vm.letters`, exactly what `activeAudioFiles` resolves — when the
    /// dashboard renders. No repo re-read, no audio-path or per-tick cost.
    /// Per-asset (case variants list separately) since routing is
    /// per-asset. Lets the researcher decide BEFORE the pilot whether the
    /// phoneme arm is valid to run.
    private var phonemeCoverageSection: some View {
        let assets    = vm.letters.sorted { $0.name < $1.name }
        let total     = assets.count
        let degrading = assets.filter { $0.phonemeAudioFiles.isEmpty }
        let covered   = total - degrading.count
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Phonem-Abdeckung (Phonem-Arm)",
                          subtitle: "Pilot-Prüfung vor dem Start: welche Buchstaben im Phonem-Arm auf Name-Audio zurückfallen")
            HStack {
                Text("Phonem-Aufnahmen vorhanden")
                Spacer()
                Text("\(covered) von \(total)")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(degrading.isEmpty ? .green : .orange)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))

            if total == 0 {
                emptyHint("Noch keine Buchstaben geladen.")
            } else if degrading.isEmpty {
                Text("Alle geladenen Buchstaben haben Phonem-Aufnahmen — der Phonem-Arm ist vollständig.")
                    .font(.caption)
                    .foregroundStyle(Color.inkSoft)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Fallen im Phonem-Arm auf Name-Audio zurück (keine Phonem-Aufnahme):")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(degrading.map(\.name).joined(separator: ", "))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Vor dem Piloten entscheiden: Phoneme aufnehmen (H5) · Buchstaben-Set einschränken · oder als Limitation dokumentieren. Im Phonem-Arm verfälscht jeder zurückfallende Buchstabe die UV — auf Studien-Geräten still zu Name-Audio, nur im Log sichtbar.")
                        .font(.caption)
                        .foregroundStyle(Color.inkSoft)
                }
                .padding(12)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Schreibmotorik

    private var schreibmotorikSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Schreibmotorik (Marquardt & Söhl, 2016)",
                          subtitle: "Mittel über alle abgeschlossenen freeWrite-Sessions")
            if let dims = vm.dashboardSnapshot.averageWritingDimensions {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                    metricTile(label: "Form (Fréchet)",
                               value: dims.form, weight: 0.40)
                    metricTile(label: "Tempo (CV²)",
                               value: dims.tempo, weight: 0.25)
                    metricTile(label: "Druck (Force-σ)",
                               value: dims.pressure, weight: 0.15)
                    metricTile(label: "Rhythmus",
                               value: dims.rhythm, weight: 0.20)
                }
                if let last = vm.lastWritingAssessment {
                    Text("Zuletzt: Form \(pct(last.formAccuracy)), Tempo \(pct(last.tempoConsistency)), Druck \(pct(last.pressureControl)), Rhythmus \(pct(last.rhythmScore)) — Gewichtetes Gesamt \(pct(last.overallScore))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.inkSoft)
                }
            } else {
                emptyHint("Noch keine freeWrite-Session abgeschlossen.")
            }
        }
    }

    // MARK: - Recognition

    private var recognitionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "KI-Erkennung",
                          subtitle: "Prediction vs. Expected je Buchstabe (letzte Stichprobe)")
            let entries = vm.allProgress
                .compactMap { (letter, p) -> (String, RecognitionSample)? in
                    guard let s = p.recognitionSamples?.last else { return nil }
                    return (letter, s)
                }
                .sorted { $0.0 < $1.0 }
            if entries.isEmpty {
                emptyHint("Noch keine Erkennungs-Daten gesammelt.")
            } else {
                VStack(spacing: 0) {
                    headerRow(["Buchstabe", "Vorhergesagt", "Konfidenz", "Korrekt"])
                    ForEach(entries, id: \.0) { letter, sample in
                        dataRow([
                            letter,
                            sample.predictedLetter,
                            String(format: "%.3f", sample.confidence),
                            sample.isCorrect ? "ja" : "nein"
                        ], correct: sample.isCorrect)
                    }
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Condition

    private var conditionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Studienarm",
                          subtitle: "Verteilung über alle Phasen-Sessions")
            let counts = Dictionary(grouping: vm.dashboardSnapshot.phaseSessionRecords,
                                     by: { $0.condition })
                .mapValues(\.count)
            VStack(spacing: 6) {
                ForEach(ThesisCondition.allCases, id: \.self) { condition in
                    HStack {
                        Text(conditionLabel(condition))
                        Spacer()
                        Text("\(counts[condition] ?? 0) Sessions")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(Color.inkSoft)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 8))
                }
            }

            // Audio axis (the pilot's primary between-subjects factor) —
            // counted separately; the two axes are orthogonal.
            sectionHeader(title: "Audio-Arm",
                          subtitle: "Verteilung über alle Phasen-Sessions")
            let audioCounts = Dictionary(grouping: vm.dashboardSnapshot.phaseSessionRecords,
                                          by: { $0.audioCondition })
                .mapValues(\.count)
            VStack(spacing: 6) {
                ForEach(PilotAudioCondition.allCases, id: \.self) { arm in
                    HStack {
                        Text("\(arm.displayName) (\(arm.rawValue))")
                        Spacer()
                        Text("\(audioCounts[arm] ?? 0) Sessions")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(Color.inkSoft)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: - Post-test (H6)

    /// Reachability for the participant's two UNTRAINED study letters —
    /// the within-child post-test the design depends on and that has no
    /// other entry point (`visibleLetterNames` filters them out of the
    /// normal practice pool by design). Tapping one starts a single COLD
    /// `freeWrite` pass (see `startPostTest(letter:)`) and leaves the
    /// parent area so the child sees the tracing canvas directly.
    private var postTestSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Post-Test (ungeübte Buchstaben)",
                          subtitle: "Einmaliger, ungeübter Schreibversuch — kein Vorführen, kein Nachspuren")
            Text("Diese \(vm.trainedSubset.untrainedLetters.count) Buchstaben hat das Kind NICHT geübt. Ein Antippen startet direkt einen einzigen freien Schreibversuch — Anschauen- und Nachspuren-Phase werden übersprungen, da sie selbst bereits Übung wären.")
                .font(.caption)
                .foregroundStyle(Color.inkSoft)
            ForEach(Array(vm.trainedSubset.untrainedLetters).sorted(), id: \.self) { letter in
                Button {
                    vm.startPostTest(letter: letter)
                    dismiss()
                } label: {
                    Label("Post-Test starten: \(letter)", systemImage: "pencil.and.outline")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Scheduler

    private var schedulerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Spaced-Repetition-Effizienz",
                          subtitle: "Pearson-Korrelation Priorität ↔ Lernfortschritt")
            let proxy = vm.dashboardSnapshot.schedulerEffectivenessProxy
            HStack {
                Text("Effektivitäts-Proxy")
                Spacer()
                Text(String(format: "r = %+.3f", proxy))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(proxy >= 0 ? .green : .orange)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            Text("Positive Werte: Scheduler priorisiert korrekt schwächere Buchstaben. Werte um 0 deuten an, dass Empfehlungen keine systematische Wirkung zeigen.")
                .font(.caption)
                .foregroundStyle(Color.inkSoft)
        }
    }

    // MARK: - Per-phase records

    private var phaseRecordsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Phasen-Sessions (letzte 20)",
                          subtitle: "Roh-Daten der letzten Trainings-Schritte")
            let recent = Array(vm.dashboardSnapshot.phaseSessionRecords.suffix(20).reversed())
            if recent.isEmpty {
                emptyHint("Noch keine Phasen-Sessions abgeschlossen.")
            } else {
                VStack(spacing: 0) {
                    headerRow(["Buchstabe", "Phase", "Wertung", "Form", "Tempo", "Druck", "Rhythmus"])
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, rec in
                        dataRow([
                            rec.letter,
                            rec.phase,
                            String(format: "%.2f", rec.score),
                            rec.formAccuracy.map     { String(format: "%.2f", $0) } ?? "—",
                            rec.tempoConsistency.map { String(format: "%.2f", $0) } ?? "—",
                            rec.pressureControl.map  { String(format: "%.2f", $0) } ?? "—",
                            rec.rhythmScore.map      { String(format: "%.2f", $0) } ?? "—"
                        ], correct: nil)
                    }
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Letter aggregate

    private var letterTableSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Buchstaben-Aggregate",
                          subtitle: "Sessions, Genauigkeit, Erkennungs-Mittel")
            let stats = vm.dashboardSnapshot.letterStats.values
                .sorted { $0.letter < $1.letter }
            if stats.isEmpty {
                emptyHint("Noch keine Sitzungs-Daten.")
            } else {
                VStack(spacing: 0) {
                    headerRow(["Buchstabe", "Sitzungen", "Ø Genauigkeit", "Trend", "KI Ø"])
                    ForEach(stats, id: \.letter) { stat in
                        let recAcc = vm.progress(for: stat.letter).recognitionAccuracy ?? []
                        let recAvg = recAcc.isEmpty ? "—" : String(format: "%.2f", recAcc.reduce(0, +) / Double(recAcc.count))
                        dataRow([
                            stat.letter,
                            "\(stat.accuracySamples.count)",
                            String(format: "%.2f", stat.averageAccuracy),
                            String(format: "%+.3f", stat.trend),
                            recAvg
                        ], correct: nil)
                    }
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.body(FontSize.md, weight: .semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Color.inkSoft)
        }
    }

    private func metricTile(label: String, value: Double, weight: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.inkSoft)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.3f", value))
                    .font(.system(.title3, design: .rounded).monospacedDigit().weight(.semibold))
                Text("(× \(String(format: "%.2f", weight)))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.inkSoft)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func headerRow(_ cells: [String]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, c in
                Text(c)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemBackground))
    }

    private func dataRow(_ cells: [String], correct: Bool?) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, c in
                Text(c)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(rowBackground(correct: correct))
    }

    private func rowBackground(correct: Bool?) -> Color {
        guard let correct else { return Color.clear }
        return correct ? Color.green.opacity(0.10) : Color.orange.opacity(0.12)
    }

    private func emptyHint(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(Color.inkSoft)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func pct(_ value: CGFloat) -> String {
        String(format: "%.3f", value)
    }

    private func conditionLabel(_ c: ThesisCondition?) -> String {
        switch c {
        case .threePhase: return "threePhase (4-Phasen)"
        case .guidedOnly: return "guidedOnly"
        case .control:    return "control"
        case .none:       return "—"
        }
    }
}
