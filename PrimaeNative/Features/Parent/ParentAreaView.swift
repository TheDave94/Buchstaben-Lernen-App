// ParentAreaView.swift
// PrimaeNative
//
// Parental gate destination. Reached only via the 2-second gear
// long-press on `WorldSwitcherRail`. Plain iOS chrome — no
// child-friendly styling, since a child should never land here.

import SwiftUI
import UIKit

struct ParentAreaView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TracingViewModel.self) private var vm

    enum Section: String, CaseIterable, Identifiable {
        case overview, research, settings, export
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview:  return "Übersicht"
            case .research:  return "Forschungs-Daten"
            case .settings:  return "Einstellungen"
            case .export:    return "Datenexport"
            }
        }
        var systemImage: String {
            switch self {
            case .overview:  return "chart.bar.fill"
            case .research:  return "chart.xyaxis.line"
            case .settings:  return "gearshape.fill"
            case .export:    return "square.and.arrow.up"
            }
        }
    }

    @State private var selection: Section? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Section.allCases) { section in
                    NavigationLink(value: section) {
                        Label(section.title, systemImage: section.systemImage)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Eltern-Bereich")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Zurück zur App") { dismiss() }
                        .accessibilityLabel("Zurück zur App")
                }
            }
        } detail: {
            detailView(for: selection ?? .overview)
        }
    }

    @ViewBuilder
    private func detailView(for section: Section) -> some View {
        switch section {
        case .overview:
            ParentDashboardView()
        case .research:
            ResearchDashboardView()
        case .settings:
            SettingsView()
        case .export:
            ExportCenterView()
        }
    }
}

// MARK: - Export center

private struct ExportCenterView: View {
    @Environment(TracingViewModel.self) private var vm
    @State private var shareURL: URL?
    @State private var showError = false

    var body: some View {
        Form {
            Section("Forschungs-Export") {
                Button {
                    export(format: .csv)
                } label: {
                    Label("CSV exportieren", systemImage: "doc.text")
                }
                Button {
                    export(format: .tsv)
                } label: {
                    Label("TSV exportieren", systemImage: "doc.plaintext")
                }
                Button {
                    export(format: .json)
                } label: {
                    Label("JSON exportieren", systemImage: "curlybraces")
                }
            }
            Section("Hinweis") {
                Text("Exportiert den vollständigen Lernfortschritt inklusive Phasen-Daten, Schreibmotorik-Dimensionen (Form, Tempo, Druck, Rhythmus) und KI-Erkennungs-Konfidenzen. Die Teilnehmer-ID wird mitgesendet. TSV passt am besten zu SPSS/R, CSV zu Excel/pandas.")
                    .font(.footnote)
                    .foregroundStyle(Color.inkSoft)
            }
        }
        .navigationTitle("Datenexport")
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let url = shareURL {
                ActivitySheet(items: [url])
            }
        }
        .alert("Export fehlgeschlagen", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Die Datei konnte nicht erstellt werden.")
        }
    }

    private func export(format: DashboardExportFormat) {
        do {
            shareURL = try ParentDashboardExporter.exportFileURL(
                from: vm.dashboardSnapshot,
                format: format,
                progress: vm.allProgress,
                rawTraces: vm.rawTraces
            )
        } catch {
            showError = true
        }
    }
}

/// Share-sheet wrapper. Module-internal so both the export center and
/// the ResearchDashboard new-participant flow share one implementation.
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
