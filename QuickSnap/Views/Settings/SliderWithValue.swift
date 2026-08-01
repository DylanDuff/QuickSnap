//
//  SliderWithValue.swift
//  QuickSnap
//

import SwiftUI

/// Slider with a trailing readout of the current value — the shared shape of
/// every numeric row in Settings (durations, padding, quality, timeouts).
/// `format` owns how the value reads, including special cases like the
/// preview duration's "Never" at the top of its range.
struct SliderWithValue: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String
    ) {
        _value = value
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range, step: step)
                .frame(maxWidth: 220)

            Text(format(value))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
    }
}
