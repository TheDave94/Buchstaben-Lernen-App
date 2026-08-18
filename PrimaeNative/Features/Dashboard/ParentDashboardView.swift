import SwiftUI
import UIKit

// MARK: - Main View

struct ParentDashboardView: View {
    @Environment(TracingViewModel.self) private var vm
    @State private var shareURL: URL?
    @State private var showExportError = false
    @State private var showSettings = false

    private var snapshot: DashboardSnapshot { vm.dashboardSnapshot }

    var body: some View {
        NavigationStack {
            List {
                ubersichtSection
                schreibqualitaetDetailsSection
                phasenSection
                ubungsverlaufSection
                starksteBuchstabenSection
                ubungNoetigSection
                papierUebertragungSection
                erkennungsGenauigkeitSection
                #if DEBUG
                if vm.showDebug {
                    forschungsmetrikenSection
                }
                #endif
            }
            .navigationTitle("Lernfortschritt")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    exportButton
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Einstellungen") {
                        showSettings = true
                    }
                }
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
            }
        }
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let url = shareURL {
                ActivityViewController(activityItems: [url])
            }
        }
        .alert("Export fehlgeschlagen", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Die Datei konnte nicht erstellt werden.")
        }
    }

    // MARK: Sections

    private var ubersichtSection: some View {
        Section("Übersicht") {
            LabeledContent("Buchstaben geübt") {
                Text("\(snapshot.letterStats.filter { !$0.value.accuracySamples.isEmpty }.count)")
                    .monospacedDigit()
            }
            LabeledContent("Tage in Folge") {
                Text("\(vm.currentStreak) \(vm.currentStreak == 1 ? "Tag" : "Tage")")
                    .monospacedDigit()
            }
            LabeledContent("Beste Serie") {
                Text("\(vm.longestStreak) \(vm.longestStreak == 1 ? "Tag" : "Tage")")
                    .monospacedDigit()
            }
            LabeledContent("Übungszeit (7 Tage)") {
                Text(formattedDuration(snapshot.totalPracticeTime(recentDays: 7)))
                    .monospacedDigit()
            }
            LabeledContent("Schreibqualität") {
                Text("\(Int(snapshot.averageFreeWriteScore * 100)) %")
                    .monospacedDigit()
            }
            if let trend = vm.writingSpeedTrend {
                LabeledContent("Schreibflüssigkeit") {
                    switch trend {
                    case .improving:
                        Text("↑ zunehmend").foregroundStyle(.green)
                    case .stable:
                        Text("→ stabil").foregroundStyle(Color.inkSoft)
                    case .declining:
                        Text("↓ abnehmend").foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    /// Per-dimension Schreibmotorik breakdown (Form / Tempo / Druck /
    /// Rhythmus). Composite in `ubersichtSection` is a 40/25/15/20
    /// weighted blend; emitted once a completed freeWrite session
    /// has produced dimension data.
    @ViewBuilder
    private var schreibqualitaetDetailsSection: some View {
        if let dims = snapshot.averageWritingDimensions {
            Section("Schreibqualität – Details") {
                dimensionRow(label: "Form",
                             value: dims.form,
                             trend: dimensionTrend(\.formAccuracy))
                dimensionRow(label: "Tempo",
                             value: dims.tempo,
                             trend: dimensionTrend(\.tempoConsistency))
                dimensionRow(label: "Druck",
                             value: dims.pressure,
                             trend: dimensionTrend(\.pressureControl))
                dimensionRow(label: "Rhythmus",
                             value: dims.rhythm,
                             trend: dimensionTrend(\.rhythmScore))
            }
        }
    }

    /// Last 5 non-nil values for a single Schreibmotorik dimension
    /// across completed freeWrite records, for the trend sparkline.
    private func dimensionTrend(_ keyPath: KeyPath<PhaseSessionRecord, Double?>) -> [Double] {
        snapshot.phaseSessionRecords
            .filter { $0.phase == "freeWrite" && $0.completed }
            .compactMap { $0[keyPath: keyPath] }
            .suffix(5)
            .map { $0 }
    }

    @ViewBuilder
    private func dimensionRow(label: String, value: Double, trend: [Double]) -> some View {
        let pct = Int((value * 100).rounded())
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label)
                Spacer()
                if trend.count >= 2 {
                    Sparkline(values: trend)
                        .frame(width: 56, height: 16)
                        .accessibilityHidden(true)
                }
                Text("\(pct) %").monospacedDigit().foregroundStyle(Color.inkSoft)
            }
            ProgressView(value: max(0, min(1, value)))
                .progressViewStyle(.linear)
        }
        .padding(.vertical, 2)
        // Collapse into one VoiceOver element so the row reads as a
        // single phrase rather than three focus stops.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(pct) Prozent")
    }
}

/// Inline sparkline over 0–1 values. Caller gates on `count >= 2`.
private struct Sparkline: View, Equatable {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard values.count >= 2 else { return }
                let xStep = geo.size.width / CGFloat(values.count - 1)
                for (idx, raw) in values.enumerated() {
                    let v = max(0, min(1, raw))
                    let x = CGFloat(idx) * xStep
                    let y = geo.size.height * (1 - CGFloat(v))
                    if idx == 0 { path.move(to: .init(x: x, y: y)) }
                    else { path.addLine(to: .init(x: x, y: y)) }
                }
            }
            .stroke(AppSurface.starGold, lineWidth: 1.5)
        }
    }
}

extension ParentDashboardView {

    private var phasenSection: some View {
        Section("Phasen-Erfolgsquote") {
            PhaseRatesView(rates: snapshot.phaseCompletionRates)
        }
    }

    private var ubungsverlaufSection: some View {
        Section("Übungsverlauf (30 Tage)") {
            PracticeTrendChart(series: snapshot.dailyPracticeMinutes(days: 30))
        }
    }

    private var starksteBuchstabenSection: some View {
        Section("Stärkste Buchstaben") {
            let top = snapshot.topLetters
            if top.isEmpty {
                Text("Noch keine Daten vorhanden.")
                    .foregroundStyle(Color.inkSoft)
            } else {
                ForEach(top, id: \.letter) { stat in
                    LetterStatRow(stat: stat, phaseScores: snapshot.phaseScores(for: stat.letter))
                }
            }
        }
    }

    private var ubungNoetigSection: some View {
        Section("Noch zu üben") {
            let weak = snapshot.lettersBelow(accuracy: 0.70)
            if weak.isEmpty {
                Text("Alle Buchstaben über 70 % – weiter so!")
                    .foregroundStyle(Color.inkSoft)
            } else {
                ForEach(weak, id: \.letter) { stat in
                    LetterStatRow(stat: stat, phaseScores: snapshot.phaseScores(for: stat.letter))
                }
            }
        }
    }

    @ViewBuilder
    private var papierUebertragungSection: some View {
        let entries = vm.allProgress
            .compactMap { letter, prog -> (String, Double)? in
                guard let score = prog.paperTransferScore else { return nil }
                return (letter, score)
            }
            .sorted(by: { $0.0 < $1.0 })
        if !entries.isEmpty {
            Section("Schreiben auf Papier") {
                ForEach(entries, id: \.0) { letter, score in
                    LabeledContent(letter) {
                        Text(paperTransferLabel(score))
                    }
                }
            }
        }
    }

    private func paperTransferLabel(_ score: Double) -> String {
        if score >= 0.9 { return "😊 super" }
        if score >= 0.4 { return "😐 okay" }
        return "😟 nochmal üben"
    }

    @ViewBuilder
    private var erkennungsGenauigkeitSection: some View {
        let entries = vm.allProgress
            .compactMap { letter, prog -> (String, [Double])? in
                guard let acc = prog.recognitionAccuracy, !acc.isEmpty else { return nil }
                return (letter, acc)
            }
            .sorted(by: { $0.0 < $1.0 })
        if !entries.isEmpty {
            Section("Buchstaben-Erkennung") {
                ForEach(entries, id: \.0) { letter, samples in
                    LabeledContent(letter) {
                        let avg = samples.reduce(0, +) / Double(samples.count)
                        Text("\(Int((avg * 100).rounded())) % (\(samples.count))")
                            .monospacedDigit()
                            .foregroundStyle(avg >= 0.7 ? .green : (avg >= 0.4 ? .orange : .red))
                    }
                    .accessibilityLabel("\(letter) erkannt zu \(Int((samples.reduce(0, +) / Double(samples.count) * 100).rounded())) Prozent bei \(samples.count) Versuchen")
                }
            }
        }
    }

    #if DEBUG
    private var forschungsmetrikenSection: some View {
        // Debug-only research-internal correlations. Toggled via
        // vm.showDebug, set from the parent area's Settings screen.
        // (There is no long-press on the phase indicator; that
        // gesture never existed on PhaseDotIndicator.)
        Section("Forschungsmetriken (Debug)") {
            LabeledContent("Scheduler-Effektivität (r)") {
                Text(String(format: "%.3f", snapshot.schedulerEffectivenessProxy))
                    .monospacedDigit()
            }
            LabeledContent("Ø Schreibqualität (gesamt)") {
                Text(String(format: "%.3f", snapshot.averageFreeWriteScore))
                    .monospacedDigit()
            }
            if let dims = snapshot.averageWritingDimensions {
                LabeledContent("  Ø Form") {
                    Text(String(format: "%.3f", dims.form)).monospacedDigit()
                }
                LabeledContent("  Ø Tempo") {
                    Text(String(format: "%.3f", dims.tempo)).monospacedDigit()
                }
                LabeledContent("  Ø Druck") {
                    Text(String(format: "%.3f", dims.pressure)).monospacedDigit()
                }
                LabeledContent("  Ø Rhythmus") {
                    Text(String(format: "%.3f", dims.rhythm)).monospacedDigit()
                }
            }
            LabeledContent("Phasensitzungen gesamt") {
                Text("\(snapshot.phaseSessionRecords.count)")
                    .monospacedDigit()
            }
            LabeledContent("Aktuelle Bedingung") {
                Text(vm.thesisConditionRawName)
                    .monospacedDigit()
            }
        }
    }
    #endif

    // MARK: Export

    private var exportButton: some View {
        Button {
            do {
                shareURL = try ParentDashboardExporter.exportFileURL(
                    from: snapshot,
                    format: .csv,
                    progress: vm.allProgress
                )
            } catch {
                showExportError = true
            }
        } label: {
            Label("Exportieren", systemImage: "square.and.arrow.up")
        }
        .accessibilityLabel("Daten exportieren")
        .accessibilityHint("Erstellt eine CSV-Datei mit dem Lernfortschritt")
    }

    // MARK: Helpers

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h) h \(m) min" }
        if m > 0 { return "\(m) min \(s) s" }
        return "\(s) s"
    }
}

// MARK: - Letter row

private struct LetterStatRow: View {
    let stat: LetterAccuracyStat
    /// Per-phase mean scores keyed by `LearningPhase.rawName`.
    let phaseScores: [String: Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(stat.letter)
                    .font(.body(FontSize.md, weight: .semibold))
                    .frame(width: 32, alignment: .leading)

                Text("\(Int(stat.averageAccuracy * 100)) %")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(accuracyColor)

                Spacer()

                trendIcon
                    .font(.subheadline)
            }

            if !phaseScores.isEmpty {
                HStack(spacing: 10) {
                    Spacer().frame(width: 32)  // align under the letter glyph
                    ForEach(LearningPhase.allCases, id: \.self) { phase in
                        phaseChip(for: phase, value: phaseScores[phase.rawName])
                    }
                    Spacer()
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// One-letter chip abbreviation. Full name is in the
    /// accessibilityLabel so VoiceOver still reads it out.
    private func abbreviation(for phase: LearningPhase) -> String {
        switch phase {
        case .observe:   return "A"   // Anschauen
        case .direct:    return "R"   // Richtung lernen
        case .guided:    return "N"   // Nachspuren
        case .freeWrite: return "S"   // Selbst schreiben
        }
    }

    private func chipColor(for phase: LearningPhase) -> Color {
        switch phase {
        case .observe:   return .blue
        case .direct:    return .indigo
        case .guided:    return .teal
        case .freeWrite: return .purple
        }
    }

    @ViewBuilder
    private func phaseChip(for phase: LearningPhase, value: Double?) -> some View {
        if let value {
            HStack(spacing: 3) {
                Circle()
                    .fill(chipColor(for: phase))
                    .frame(width: 6, height: 6)
                Text("\(abbreviation(for: phase)) \(Int((value * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.inkSoft)
            }
            .accessibilityLabel("\(phase.displayName) \(Int((value * 100).rounded())) Prozent")
        }
    }

    private var accuracyColor: Color {
        let a = stat.averageAccuracy
        if a >= 0.85 { return .green }
        if a >= 0.70 { return .orange }
        return .red
    }

    @ViewBuilder
    private var trendIcon: some View {
        if stat.trend > 0.02 {
            Image(systemName: "arrow.up")
                .foregroundStyle(.green)
                .accessibilityLabel("steigend")
        } else if stat.trend < -0.02 {
            Image(systemName: "arrow.down")
                .foregroundStyle(.red)
                .accessibilityLabel("fallend")
        } else {
            Image(systemName: "arrow.right")
                .foregroundStyle(Color.inkSoft)
                .accessibilityLabel("stabil")
        }
    }
}

// MARK: - Share sheet wrapper

private struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
