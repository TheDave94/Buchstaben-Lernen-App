// StudyBuildCanary.swift
// PrimaeNative
//
// SPIKE ONLY — delete before the real STUDY_BUILD work lands.
//
// Answers one question: does the `STUDY_BUILD` compilation condition
// set by the Xcode project actually reach *this* target, which is a
// local SwiftPM package target rather than a project target?
//
// Exactly one of the two markers is compiled into the binary, so a
// `strings` scan can tell "flag arrived" from "flag did not arrive"
// — and cannot report success by finding nothing.

public enum StudyBuildCanary {
    /// Referenced from `PrimaeApp.init()` so the object file is pulled
    /// out of the static archive and the literal survives linking.
    public static let marker: String = {
        #if STUDY_BUILD
        return "PRIMAE_CANARY_PKG_ON"
        #else
        return "PRIMAE_CANARY_PKG_OFF"
        #endif
    }()
}
