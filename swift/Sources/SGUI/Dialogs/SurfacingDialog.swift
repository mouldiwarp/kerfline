// Flatten the top of the stock (or a spoilboard): set work zero at the front-left corner, measure
// the area, and the zig-zag program is generated and added to the library. As 1.0's SurfacingDialog.

import SGCore
import SGLibrary
import SGNet
import SwiftUI

struct SurfacingDialog: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var p = SurfacingStore.load()
    @State private var busy = false

    var body: some View {
        @Bindable var model = model
        if let s = model.state {
            content(s).sheet(isPresented: $model.probeOver) { ProbeDialog(nested: true).environment(model) }
        }
    }

    private func content(_ s: AppState) -> some View {
        let m = s.machine
        let locked = !s.machineReady || s.jobActive || m.status != .idle
        let measured = p.lengthX > 0 && p.widthY > 0
        let problems = measured ? checkSurfacing(p) : []
        let plan = measured && problems.isEmpty ? try? planSurfacing(p) : nil
        let est = plan.map { analyzeProgram($0.gcode, options: InterpreterOptions(rapidRate: s.config.rapidRate)) }
        let outside = est.map { a in axesOutside(a.bounds ?? Bounds(min: .zero, max: .zero), envelope: s.config.envelope, wco: m.wco) } ?? []
        return DialogFrame(eyebrow: "Surfacing", title: "Flatten the stock", width: 640, height: 520) {
            Steps {
                HStack(spacing: 8) {
                    Text("Jog the bit over the front-left corner of the area, then")
                    Button("Zero XY here") { model.send(.zero(axes: [.X, .Y])) }.gccButton(.normal, .small).disabled(locked)
                }
                HStack(spacing: 8) {
                    Text("Touch the bit to the highest point of the surface, then")
                    Button("Zero Z here") { model.send(.zero(axes: [.Z])) }.gccButton(.normal, .small).disabled(locked)
                    Text("or")
                    Button("Probe Z…") { model.openProbe() }.gccButton(.normal, .small).disabled(locked)
                }
                Text("Measure the area and set the cutter below.")
            }
            HStack(spacing: 6) {
                Text("Work position").foregroundStyle(Color.steel)
                Text(xyz(m.wpos)).font(.mono)
            }
            Eyebrow("Area")
            HStack(alignment: .top, spacing: 12) {
                Field(label: "Length (X)", unit: "mm") { NumberField(value: $p.lengthX, placeholder: "measure it", zeroEmpty: true) }
                Field(label: "Width (Y)", unit: "mm") { NumberField(value: $p.widthY, placeholder: "measure it", zeroEmpty: true) }
                Field(label: "Depth to remove", unit: "mm") { NumberField(value: $p.totalDepth) }
            }
            Eyebrow("Cutter")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Field(label: "Diameter", unit: "mm") { NumberField(value: $p.toolDiameter) }
                    Field(label: "Cutting depth", unit: "mm", help: "Length of the flutes") { NumberField(value: $p.fluteLength) }
                    Field(label: "Most per pass", unit: "mm") { NumberField(value: $p.stepDown) }
                }
                GridRow {
                    Field(label: "Stepover", unit: "% of dia") { NumberField(value: $p.stepoverPct) }
                    Field(label: "Ramp", unit: "°") { NumberField(value: $p.rampAngle) }
                    Field(label: "Past edges", unit: "mm") { NumberField(value: $p.overhang) }
                }
                GridRow {
                    Field(label: "Feed", unit: "mm/min") { NumberField(value: $p.feed) }
                    Field(label: "Ramp feed", unit: "mm/min") { NumberField(value: $p.rampFeed) }
                    Field(label: "Spindle", unit: "rpm") { NumberField(value: $p.spindleRpm) }
                }
                GridRow {
                    Field(label: "Safe Z", unit: "mm") { NumberField(value: $p.safeZ) }
                }
            }
            if !problems.isEmpty { Note(.danger, problems.joined(separator: " ")) }
            if let plan, let est {
                Note(kind: .info) {
                    Text("\(plan.levels) pass\(plan.levels == 1 ? "" : "es") of \(plan.lines) lines, \(fixed(plan.stepover, 1)) mm apart · ramps in over \(fixed(plan.rampLength, 0)) mm at \(short(p.rampAngle))° · about \(formatDuration(est.estSeconds))")
                    if plan.overhang < p.overhang - 0.001 {
                        Text("Past edges cut to \(fixed(plan.overhang, 1)) mm: the bit can't go further past the edge than its radius.").foregroundStyle(Color.steel)
                    }
                    Text("The bit reaches X \(fixed(-plan.overhang, 1)) to \(fixed(p.lengthX + plan.overhang, 1)) and Y \(fixed(-p.toolDiameter / 2 - plan.overhang, 1)) to \(fixed(p.widthY + p.toolDiameter / 2 + plan.overhang, 1)). Clear any clamps.")
                        .foregroundStyle(Color.steel)
                }
                if !outside.isEmpty, m.homed == true {
                    Note(.warn, "⚠ From this work zero the program goes outside the machine's travel in \(outside.joined(separator: ", ")). Move work zero or make the area smaller.")
                }
            }
        } actions: {
            Button("Reset cutter settings") {
                var d = SurfacingParams.defaults
                d.lengthX = p.lengthX
                d.widthY = p.widthY
                p = d
            }
            .gccButton(.ghost)
            Spacer()
            Button("Cancel") { dismiss() }.gccButton().keyboardShortcut(.cancelAction)
            Button(busy ? "Adding…" : "Add to library") {
                guard let plan, let instance = model.instance else { return }
                busy = true
                Task {
                    do {
                        let item = try await instance.upload(Data(plan.gcode.utf8), AddOptions(name: plan.name, source: "Surfacing"))
                        model.previewId = item.id
                        model.toast(.info, "Added \(item.name)")
                        dismiss()
                    } catch {
                        model.toast(.error, "Couldn't add the program: \(error.localizedDescription)")
                    }
                    busy = false
                }
            }
            .gccButton(.primary, .large).keyboardShortcut(.defaultAction).disabled(plan == nil || busy)
        }
        .onChange(of: p) { _, v in SurfacingStore.save(v) }
    }
}
