// PracticeTrendChart.swift
// PrimaeNative
//
// Bar chart of daily practice minutes over the last 30 days. Source
// is `DashboardSnapshot.dailyPracticeMinutes`, which zero-fills
// skipped days so the timeline reads continuously.
//
// COMPILED OUT OF THE STUDY BUILD. Its sole consumer, ParentDashboardView,
// is already excluded — this closes the gap between "unreferenced from
// any study-build file" and "absent from the study binary" (Swift
// still compiles an unreferenced top-level type into the target). Same
// reasoning as the six CanvasOverlay surfaces already excluded. The CI
// identity scan asserts this via SURFACES (ios-build.yml).
#if !STUDY_BUILD
import SwiftUI
import Charts

struct PracticeTrendChart: View {

    /// Oldest-first (day, minutes) tuples — pass exactly what
    /// `DashboardSnapshot.dailyPracticeMinutes(days:)` returns.
    let series: [(date: Date, minutes: Double)]

    private struct Datum: Identifiable {
        let id: Date
        let minutes: Double
    }
    private var data: [Datum] {
        series.map { Datum(id: $0.date, minutes: $0.minutes) }
    }

    /// Suppress the chart when the whole window is empty.
    private var hasAnyPractice: Bool {
        series.contains { $0.minutes > 0 }
    }

    var body: some View {
        if hasAnyPractice {
            Chart(data) { d in
                BarMark(
                    x: .value("Tag", d.id, unit: .day),
                    y: .value("Minuten", d.minutes)
                )
                .foregroundStyle(Color.blue.gradient)
                .cornerRadius(2)
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
            }
            .chartXAxis {
                // Sparse week-grain ticks so 30 days fit without overlap.
                AxisMarks(values: .stride(by: .day, count: 7)) { value in
                    AxisValueLabel(format: .dateTime.day().month(.narrow))
                }
            }
            .frame(height: 140)
            .accessibilityLabel("Übungsverlauf der letzten 30 Tage in Minuten pro Tag")
        } else {
            Text("Noch keine Übungsdaten – starte eine Übung!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
        }
    }
}
#endif
