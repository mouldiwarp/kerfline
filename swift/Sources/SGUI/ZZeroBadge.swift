// Where the file expects Z zero: on the material or on the spoilboard. Getting it wrong cuts a stock thickness too
// deep or in the air, so it sits under the file name in the job panel and the 3D view, and in the start checklist.

import SGCore
import SwiftUI

struct ZZeroBadge: View {
    let ref: ZZeroReference?
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(label).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
        .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
        .help(ref?.advice ?? "The file doesn't say where Z zero is. Check in the program that made it before probing.")
    }

    private var label: String {
        guard let ref else { return compact ? "Z zero: not stated" : "Z zero: not stated in the file" }
        return "Z zero: \(ref.title)"
    }
    private var icon: String {
        switch ref {
        case .materialTop: "square.stack.3d.up"
        case .spoilboard: "square.3.layers.3d.bottom.filled"
        case nil: "questionmark.circle"
        }
    }
    private var color: Color {
        switch ref {
        case .materialTop: .gold
        case .spoilboard: .warn
        case nil: .steel
        }
    }
}

/// The checklist wording for zeroing Z on this file.
func zZeroCheck(_ ref: ZZeroReference?) -> String {
    switch ref {
    case .materialTop: "Z zero on the TOP of the material"
    case .spoilboard: "Z zero on the SPOILBOARD, not on the material"
    case nil: "Z zero where the program that made this file expects it (the file doesn't say)"
    }
}
