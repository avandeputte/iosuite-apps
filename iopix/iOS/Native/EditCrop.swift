import SwiftUI

/// Cropping a photo: drag the box's corners or move it, optionally at a fixed shape. The server crops the file
/// (JPEG without loss), moves the faces with it and keeps a copy for Undo.
struct EditCropView: View {
    let detail: EditDetail
    let done: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rect = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)   // in 0...1 of the picture
    @State private var start: CGRect?
    @State private var ratio: Double = 0  // 0: free; else width / height of the photo's pixels
    @State private var saving = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let space = CGSize(width: geo.size.width - 32, height: geo.size.height - 32)
                let fit = EditFacesView.fitted(CGSize(width: detail.width, height: detail.height), in: space).offsetBy(dx: 16, dy: 16)
                ZStack(alignment: .topLeading) {
                    RemoteImage(path: "preview/\(detail.id)", fit: true)
                        .frame(width: fit.width, height: fit.height).position(x: fit.midX, y: fit.midY)
                    let r = CGRect(x: fit.minX + rect.minX * fit.width, y: fit.minY + rect.minY * fit.height,
                                   width: rect.width * fit.width, height: rect.height * fit.height)
                    // dim outside the box
                    Path { p in p.addRect(fit); p.addRect(r) }.fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    Rectangle().strokeBorder(.white, lineWidth: 2)
                        .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                        .gesture(DragGesture().onChanged { v in
                            let s = start ?? rect
                            if start == nil { start = rect }
                            var n = s.offsetBy(dx: v.translation.width / fit.width, dy: v.translation.height / fit.height)
                            n.origin.x = min(max(0, n.minX), 1 - n.width); n.origin.y = min(max(0, n.minY), 1 - n.height)
                            rect = n
                        }.onEnded { _ in start = nil })
                    ForEach(0..<4, id: \.self) { c in
                        let pt = CGPoint(x: c % 2 == 0 ? r.minX : r.maxX, y: c < 2 ? r.minY : r.maxY)
                        Circle().fill(.white).frame(width: 22, height: 22).shadow(radius: 2)
                            .position(pt)
                            .gesture(DragGesture().onChanged { v in drag(corner: c, to: v.location, fit: fit) }.onEnded { _ in start = nil })
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                    Picker("Shape", selection: $ratio) {
                        Text("Free").tag(0.0); Text("Square").tag(1.0); Text("4:3").tag(4.0 / 3); Text("3:2").tag(1.5); Text("16:9").tag(16.0 / 9)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: ratio) { _, _ in applyRatio() }
                }
                .padding().background(.bar)
            }
            .navigationTitle("Crop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { CloseLabel("Cancel") } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button { Task { await save() } } label: { BarText("Crop") } }
                }
            }
        }
    }

    /// Moves one corner; with a fixed shape the box keeps it, growing from the opposite corner.
    private func drag(corner c: Int, to p: CGPoint, fit: CGRect) {
        let x = min(max(0, (p.x - fit.minX) / fit.width), 1), y = min(max(0, (p.y - fit.minY) / fit.height), 1)
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        if c % 2 == 0 { minX = min(x, maxX - 0.05) } else { maxX = max(x, minX + 0.05) }
        if c < 2 { minY = min(y, maxY - 0.05) } else { maxY = max(y, minY + 0.05) }
        var n = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if ratio > 0, detail.width > 0, detail.height > 0 {
            // the shape is of pixels: in 0...1 terms height = width * (photoW / photoH) / ratio
            let h = n.width * detail.width / detail.height / ratio
            if c < 2 { n.origin.y = maxY - h }
            n.size.height = h
            if n.minY < 0 || n.maxY > 1 { return }
        }
        rect = n
    }

    private func applyRatio() {
        guard ratio > 0, detail.width > 0, detail.height > 0 else { return }
        var w = rect.width, h = w * detail.width / detail.height / ratio
        if h > 1 { h = 1; w = h * detail.height / detail.width * ratio }
        rect = CGRect(x: min(max(0, rect.midX - w / 2), 1 - w), y: min(max(0, rect.midY - h / 2), 1 - h), width: w, height: h)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let px = [Int((rect.minX * detail.width).rounded()), Int((rect.minY * detail.height).rounded()),
                  Int((rect.width * detail.width).rounded()), Int((rect.height * detail.height).rounded())]
        do {
            try await EditAPI.post("api/photos/crop", ["id": detail.id, "rect": px])
            done()
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// Exposure, contrast, saturation, warmth, straightening and auto levels, saved as a new version beside the
/// original (which is not changed). The preview here is approximate; the server renders the full size.
struct EditAdjustView: View {
    let detail: EditDetail
    let done: (Int, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var exposure = 0.0
    @State private var contrast = 0.0
    @State private var saturation = 0.0
    @State private var warmth = 0.0
    @State private var angle = 0.0
    @State private var autolevel = false
    @State private var saving = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    let a = abs(angle) * .pi / 180, r = detail.height > 0 ? detail.width / detail.height : 1.5
                    let s = angle == 0 ? 1 : cos(a) + sin(a) * max(r, 1 / r)
                    RemoteImage(path: "preview/\(detail.id)", fit: true)
                        .brightness(exposure * 0.15)
                        .contrast(1 + contrast / 100)
                        .saturation(1 + saturation / 100)
                        .colorMultiply(warmth >= 0 ? Color(red: 1, green: 1 - warmth / 800, blue: 1 - warmth / 300)
                                                  : Color(red: 1 + warmth / 300, green: 1 + warmth / 800, blue: 1))
                        .rotationEffect(.degrees(angle))
                        .scaleEffect(s)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                Form {
                    slider("Exposure", $exposure, -2...2, 0.1, " EV")
                    slider("Contrast", $contrast, -60...60, 1, "")
                    slider("Saturation", $saturation, -100...100, 1, "")
                    slider("Warmth", $warmth, -100...100, 1, "")
                    slider("Straighten", $angle, -15...15, 0.5, "°")
                    Toggle("Auto levels", isOn: $autolevel)
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                }
                .frame(maxHeight: 330)
            }
            .navigationTitle("Adjust")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { CloseLabel("Cancel") } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button { Task { await save() } } label: { BarText("Save as new version") } }
                }
            }
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text((value.wrappedValue > 0 ? "+" : "") + (step < 1 ? String(format: "%.1f", value.wrappedValue) : "\(Int(value.wrappedValue))") + unit)
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let r = try await EditAPI.post("api/photos/adjust", ["id": detail.id, "exposure": exposure, "contrast": contrast,
                                                                  "saturation": saturation, "warmth": warmth, "angle": angle, "autolevel": autolevel])
            done((r["id"] as? NSNumber)?.intValue ?? detail.id, r["name"] as? String ?? "a new version")
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
