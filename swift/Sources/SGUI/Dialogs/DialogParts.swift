// The pieces the dialogs share, in the style of 1.0's modals: a gold eyebrow and a title, numbered
// steps, label/value rows, coloured notes and number fields.

import SGCore
import SwiftUI

struct DialogFrame<Content: View, Actions: View>: View {
    let eyebrow: String
    let title: String
    var width: CGFloat = 540
    /// Scroll the content in a fixed height (long dialogs).
    var height: CGFloat?
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(eyebrow.uppercased()).font(.heading).tracking(1.6).foregroundStyle(Color.gold)
            Text(title).font(.system(size: 19, weight: .semibold)).padding(.top, 4).lineLimit(2)
            Group {
                if let height {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) { content }.padding(.vertical, 14).padding(.trailing, 8)
                    }
                    .frame(height: height)
                } else {
                    VStack(alignment: .leading, spacing: 12) { content }.padding(.vertical, 14)
                }
            }
            HStack(spacing: 8) { actions }.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
        .frame(width: width)
        .background(Color.slate)
        .foregroundStyle(Color.offwhite)
        .font(.system(size: 13))
    }
}

/// Numbered steps.
struct Steps<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group(subviews: content) { items in
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.gold).frame(width: 14, alignment: .trailing)
                        item.fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// Label/value rows.
struct KV: View {
    var rows: [(String, String)]
    var mono: Set<String> = []
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { k, v in
                GridRow {
                    Text(k).foregroundStyle(Color.steel)
                    Text(v).font(mono.contains(k) ? .mono : .system(size: 13)).textSelection(.enabled)
                }
            }
        }
    }
}

/// A coloured note (1.0's `.banner` inside a modal).
struct Note<Content: View>: View {
    enum Kind { case info, ok, warn, danger }
    var kind: Kind
    @ViewBuilder var content: Content
    var body: some View {
        let c: Color = switch kind {
        case .info: .info
        case .ok: .ok
        case .warn: .warn
        case .danger: .danger
        }
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) { content }.font(.system(size: 12.5)).padding(.vertical, 8)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.leading, 13)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 5).fill(c.opacity(0.12)))
        .overlay(alignment: .leading) { Rectangle().fill(c).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

extension Note {
    init(_ kind: Kind, _ text: String) where Content == Text {
        self.init(kind: kind) { Text(text) }
    }
}

/// Small grey text.
struct Muted: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Color.steel).fixedSize(horizontal: false, vertical: true)
    }
}

/// A number field that updates as you type (0 when empty).
struct NumberField: View {
    @Binding var value: Double
    var placeholder = ""
    /// Show 0 as empty (fields that must be measured).
    var zeroEmpty = false
    @State private var text = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .font(.mono)
            .gccField()
            .onAppear { text = shown(value) }
            .onChange(of: text) { _, t in
                let v = Double(t.trimmingCharacters(in: .whitespaces)) ?? 0
                if v != value { value = v }
            }
            .onChange(of: value) { _, v in
                if (Double(text.trimmingCharacters(in: .whitespaces)) ?? 0) != v { text = shown(v) }
            }
    }

    private func shown(_ v: Double) -> String { zeroEmpty && v == 0 ? "" : short(v) }
}

/// A labelled field above its input.
struct Field<Content: View>: View {
    let label: String
    var unit: String?
    var help: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 12))
                if let unit { Text("(\(unit))").font(.system(size: 12)).foregroundStyle(Color.steel) }
            }
            content
        }
        .help(help ?? "")
    }
}

/// The reason a dialog's main button is disabled, under it.
struct BlockedHint: View {
    let text: String?
    var body: some View {
        if let text { Text(text).font(.system(size: 12)).foregroundStyle(Color.steel).frame(maxWidth: .infinity, alignment: .trailing) }
    }
}
