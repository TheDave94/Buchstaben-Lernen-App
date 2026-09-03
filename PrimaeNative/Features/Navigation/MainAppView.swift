// MainAppView.swift
// PrimaeNative
//
// Root view. Hosts the persistent WorldSwitcherRail on the left and
// swaps the right-hand content between the three worlds. Parent
// area is gated behind the gear long-press (fullScreenCover).

import SwiftUI

public struct MainAppView: View {
    @Environment(TracingViewModel.self) private var vm
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Persisted as the AppWorld raw value because `@AppStorage`
    /// only supports plain Codable scalars.
    @AppStorage("de.flamingistan.primae.activeWorld")
    private var activeWorldRaw: String = AppWorld.schule.rawValue
    @State private var showParentArea = false

    public init() {}

    /// Two-way binding around `activeWorldRaw`. Falls back to
    /// `.schule` for unrecognised values from future builds.
    private var activeWorldBinding: Binding<AppWorld> {
        Binding(
            get: { AppWorld(rawValue: activeWorldRaw) ?? .schule },
            set: { activeWorldRaw = $0.rawValue }
        )
    }

    private var activeWorld: AppWorld {
        AppWorld(rawValue: activeWorldRaw) ?? .schule
    }

    public var body: some View {
        // Onboarding owns the full screen on first run; no rail until the
        // user has reached the main experience.
        //
        // A study build ships already-onboarded (Q4): the proctor prepares
        // the device once, on a normal build. The branch is COMPILED OUT
        // rather than short-circuited, so `OnboardingView` is never
        // referenced and the notification-permission request at its trigger
        // goes with it.
        #if STUDY_BUILD
        mainShell
        #else
        if !vm.isOnboardingComplete {
            OnboardingView()
        } else {
            mainShell
        }
        #endif
    }

    /// The rail + world shell. Extracted so the onboarding branch above can
    /// be compiled out as a COMPLETE STATEMENT in each arm — a `#if` cannot
    /// split an `if`/`else` across its arms, which is how the first attempt
    /// at this failed.
    private var mainShell: some View {
        HStack(spacing: 0) {
            WorldSwitcherRail(
                activeWorld: activeWorldBinding,
                showParentArea: $showParentArea
            )
            worldContent
        }
        // Paper canvas behind the shell; each world overlays its
        // own tinted band via `WorldPalette.background(for:)`.
        .background(Color.paperDeep.ignoresSafeArea())
        .ignoresSafeArea()
        .fullScreenCover(isPresented: $showParentArea) {
            ParentAreaView()
                .environment(vm)
        }
        .onChange(of: activeWorldRaw) { _, _ in
            #if !STUDY_BUILD
            // Leaving Werkstatt — drop freeform so the other worlds see
            // a clean VM state. Werkstatt is compiled out of the study
            // build, so nothing can enter freeform there.
            if activeWorld != .werkstatt, vm.writingMode == .freeform {
                vm.exitFreeformMode()
            }
            #endif
            // Leaving Schule — halt the in-flight phase-entry
            // voiceover. Phase prompts are Schule-only context;
            // letting them bleed into Sterne or Werkstatt right
            // after onboarding is confusing for the child.
            if activeWorld != .schule {
                vm.prompts.stop()
            }
        }
    }

    @ViewBuilder
    private var worldContent: some View {
        Group {
            switch activeWorld {
            case .schule:
                SchuleWorldView()
            #if !STUDY_BUILD
            case .werkstatt:
                WerkstattWorldView()
            case .fortschritte:
                FortschritteWorldView(onLetterSelected: { letter in
                    vm.loadLetter(name: letter)
                    activeWorldRaw = AppWorld.schule.rawValue
                })
            #endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .opacity
        ))
        // Respect Reduce Motion — skip the 300 ms slide for users
        // who disabled motion; world still swaps.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: activeWorld)
    }
}
