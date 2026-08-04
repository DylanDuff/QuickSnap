//
//  ProbeCanvas.swift
//  QuickSnap
//
//  Shared plumbing for the annotation-window probes: a handle on the live
//  canvas controller and a log sink, so a probe doesn't have to thread
//  access through the view layers to reach what it's measuring.
//

import Foundation

@MainActor
enum ProbeCanvas {
    /// True when any probe is running — the only condition under which the
    /// canvas controller publishes itself here.
    static var isAnyProbeEnabled: Bool {
        UndoProbe.isEnabled || FreeZoomProbe.isEnabled
    }

    /// Set by `MarkupCanvasController.init` while a probe is running.
    static weak var current: MarkupCanvasController?

    /// Routes to whichever probe is running, so production code can log
    /// through one call rather than knowing which harness is listening.
    static func log(_ message: @autoclosure () -> String) {
        guard isAnyProbeEnabled else { return }
        let text = message()
        UndoProbe.log(text)
        FreeZoomProbe.log(text)
    }
}
