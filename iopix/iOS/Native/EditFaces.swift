import SwiftUI

/// The faces on one photo, boxed on the picture: tap a box to name it, confirm a suggestion, forget or ignore it,
/// use it as the person's badge picture, or remove it. "Add a face" draws a new box for someone. People tagged
/// without a box are listed below, and can be taken off.
struct EditFacesView: View {
    let photo: Int
    var changed: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var catalog = EditCatalog.shared
    @State private var detail: EditDetail?
    @State private var chosen: EditDetail.Face?
    @State private var naming: EditDetail.Face?
    @State private var drawing = false
    @State private var drawStart: CGPoint?
    @State private var drawRect: CGRect?
    @State private var newBox: [Int]?
    @State private var adjusting: EditDetail.Face?  // its box is being drawn again
    @State private var toast: String?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let d = detail {
                    picture(d)
                    list(d)
                } else if let problem {
                    Text(problem).foregroundStyle(.secondary).padding(40)
                } else {
                    ProgressView().frame(maxHeight: .infinity)
                }
            }
            .background(Color.black.opacity(0.92).ignoresSafeArea())
            .navigationTitle("Faces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .coverBar("Faces") {
                Button { dismiss() } label: { CloseLabel("Done") }
            } trailing: {
                Button { drawing.toggle(); drawRect = nil; adjusting = nil } label: { BarText(drawing ? "Cancel" : "Add a face") }
            }
            .editToast($toast)
        }
        .task { await load(); await catalog.load() }  // the photo first: the library summary can take a moment
        // a change made here comes back from the server's index a moment later: the boxes are reloaded then too
        .onReceive(NotificationCenter.default.publisher(for: .iopixPhotoChanged)) { n in
            if (n.userInfo?["photo"] as? Int) == photo { Task { await load() } }
        }
        .confirmationDialog(chosen?.label ?? "Face", isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }), titleVisibility: .visible) {
            if let f = chosen { menu(f) }
        }
        .sheet(item: $naming) { f in
            EditPersonPicker(photo: photo, title: f.kind == .confirmed ? "Who is this instead?" : "Who is this?") { person in
                Task { await op(["op": "name", "image": photo, "rect": f.rect, "tag": person.id], "Named \(person.name).") }
            }
        }
        .sheet(isPresented: Binding(get: { newBox != nil }, set: { if !$0 { newBox = nil } })) {
            EditPersonPicker(photo: photo, title: "Who is in the new box?") { person in
                if let r = newBox { Task { await op(["op": "add", "image": photo, "rect": r, "tag": person.id], "Added \(person.name).") } }
            }
        }
    }

    // MARK: the picture with its boxes

    private func picture(_ d: EditDetail) -> some View {
        GeometryReader { geo in
            let fit = Self.fitted(CGSize(width: d.width, height: d.height), in: geo.size)
            ZStack(alignment: .topLeading) {
                RemoteImage(path: "preview/\(photo)", fit: true)
                    .frame(width: fit.width, height: fit.height)
                    .position(x: fit.midX, y: fit.midY)
                ForEach(d.faces) { f in
                    let r = box(f, d, fit)
                    Button { chosen = f } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(color(f), style: StrokeStyle(lineWidth: 2, dash: f.kind == .confirmed ? [] : [5, 3]))
                            .background(Color.white.opacity(0.001))
                            .overlay(alignment: .bottom) {
                                Text(f.label).font(.caption2.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(color(f).opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                                    .fixedSize().offset(y: 18)
                            }
                    }
                    .buttonStyle(.plain)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                    .opacity(drawing ? 0.4 : 1)
                    .disabled(drawing)
                }
                if let rect = drawRect {
                    Rectangle().strokeBorder(Hue.green, lineWidth: 2).background(Hue.green.opacity(0.12))
                        .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4).onChanged { v in
                let a = v.startLocation, b = v.location
                drawRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).intersection(fit)
            }.onEnded { _ in
                guard let rect = drawRect, rect.width > 12, rect.height > 12 else { drawRect = nil; return }
                let sx = d.width / fit.width, sy = d.height / fit.height
                let box = [Int((rect.minX - fit.minX) * sx), Int((rect.minY - fit.minY) * sy), Int(rect.width * sx), Int(rect.height * sy)]
                if let f = adjusting {
                    adjusting = nil
                    Task { await op(["op": "move", "image": photo, "rect": f.rect, "new_rect": box], "Box adjusted.") }
                } else {
                    newBox = box
                }
                drawing = false
                drawRect = nil
            }, including: drawing ? .all : .subviews)
        }
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) {
            if drawing {
                Text(adjusting != nil ? "Drag the new box over \(adjusting?.label ?? "the face")" : "Drag over the face to box it").font(.footnote).foregroundStyle(.white)
                    .padding(8).background(.black.opacity(0.6), in: Capsule()).padding(8)
            }
        }
    }

    private func list(_ d: EditDetail) -> some View {
        let boxed = Set(d.faces.compactMap { $0.kind == .confirmed ? $0.tag : nil })
        let unboxed = d.people.filter { !boxed.contains($0.id) }
        let unknown = d.faces.filter { $0.kind == .unknown }.count
        return VStack(alignment: .leading, spacing: 8) {
            if d.faces.isEmpty { Text("No faces found on this photo yet. Use Add a face, or Look for faces in the editing tools.").font(.footnote) }
            if unknown > 0 { Text("\(unknown) unnamed face\(unknown == 1 ? "" : "s"): tap one to say who it is.").font(.footnote) }
            ForEach(unboxed) { p in
                HStack {
                    Label("\(p.name), tagged without a box", systemImage: "person")
                    Spacer()
                    Button("Take off") { Task { await op(["op": "untag", "image": photo, "tag": p.id], "\(p.name) taken off this photo.") } }
                        .font(.footnote)
                }
                .font(.footnote)
            }
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func menu(_ f: EditDetail.Face) -> some View {
        let rect = f.rect
        switch f.kind {
        case .confirmed:
            Button("Someone else…") { naming = f }
            Button("Adjust the box…") { adjusting = f; drawing = true; drawRect = nil }
            if let t = f.tag {
                Button("Use as \(f.name ?? "their") badge picture") { Task { await badge(t, f.name ?? "") } }
            }
            Button("Forget the name") { Task { await op(["op": "unknown", "image": photo, "rect": rect], "Name removed; the face stays as unknown.") } }
            Button("Not a face to name (ignore)") { Task { await op(["op": "ignore", "image": photo, "rect": rect], "Face ignored.") } }
            Button("Remove this face", role: .destructive) { Task { await op(["op": "remove", "image": photo, "rect": rect], "Face removed.") } }
        case .suggested:
            Button("Yes, this is \(f.name ?? "them")") { Task { await op(["op": "confirm", "image": photo, "rect": rect], "Confirmed.") } }
            Button("No, someone else…") { naming = f }
            Button("Not a face to name (ignore)") { Task { await op(["op": "ignore", "image": photo, "rect": rect], "Face ignored.") } }
            Button("Remove this box", role: .destructive) { Task { await op(["op": "remove", "image": photo, "rect": rect], "Removed.") } }
        case .unknown:
            Button("Who is this?…") { naming = f }
            Button("Adjust the box…") { adjusting = f; drawing = true; drawRect = nil }
            Button("Not a face to name (ignore)") { Task { await op(["op": "ignore", "image": photo, "rect": rect], "Face ignored.") } }
            Button("Remove this box", role: .destructive) { Task { await op(["op": "remove", "image": photo, "rect": rect], "Removed.") } }
        case .ignored:
            Button("Who is this?…") { naming = f }
            Button("Keep as an unknown face") { Task { await op(["op": "unknown", "image": photo, "rect": rect], "Kept as unknown.") } }
            Button("Remove this box", role: .destructive) { Task { await op(["op": "remove", "image": photo, "rect": rect], "Removed.") } }
        }
    }

    private func color(_ f: EditDetail.Face) -> Color {
        switch f.kind {
        case .confirmed: return Hue.green
        case .suggested: return Hue.amber
        case .unknown: return Hue.blue
        case .ignored: return .gray
        }
    }

    private func box(_ f: EditDetail.Face, _ d: EditDetail, _ fit: CGRect) -> CGRect {
        guard d.width > 0, d.height > 0 else { return .zero }
        return CGRect(x: fit.minX + f.x / d.width * fit.width, y: fit.minY + f.y / d.height * fit.height,
                      width: max(16, f.w / d.width * fit.width), height: max(16, f.h / d.height * fit.height))
    }

    /// Where a picture of `size` sits when fitted (whole, centred) in `space`.
    static func fitted(_ size: CGSize, in space: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, space.width > 0, space.height > 0 else { return CGRect(origin: .zero, size: space) }
        let s = min(space.width / size.width, space.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: (space.width - w) / 2, y: (space.height - h) / 2, width: w, height: h)
    }

    // MARK: server

    private func load() async {
        do { detail = try await EditAPI.detail(photo) } catch { problem = error.localizedDescription }
    }

    private func op(_ o: [String: Any], _ said: String) async {
        do {
            try await PhotoChange.faceOp(o)
            toast = said
            changed()
            await load()
        } catch {
            toast = "That face change did not go through: \(error.localizedDescription)"
        }
    }

    private func badge(_ tag: Int, _ name: String) async {
        do {
            try await EditAPI.post("api/tags/op", ["op": "icon", "id": tag, "photo": photo])
            toast = "Now \(name)'s badge picture."
            changed()
        } catch {
            toast = error.localizedDescription
        }
    }
}

/// Choosing a person: the people in the photos around this one first, then everyone, or a new person.
struct EditPersonPicker: View {
    let photo: Int
    let title: String
    let pick: (EditCatalog.Entry) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var catalog = EditCatalog.shared
    @State private var search = ""
    @State private var nearby: [Int] = []
    @State private var family: Int?
    @State private var making = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                let q = search.trimmingCharacters(in: .whitespaces)
                if !q.isEmpty, !catalog.people.contains(where: { $0.name.caseInsensitiveCompare(q) == .orderedSame }) {
                    Section {
                        Picker("Family", selection: $family) {
                            Text("None").tag(Int?.none)
                            ForEach(families) { f in Text(f.name).tag(Int?.some(f.id)) }
                        }
                        Button { Task { await make(q) } } label: {
                            if making { ProgressView() } else { Label("New person “\(q)”", systemImage: "person.badge.plus") }
                        }
                        .disabled(making)
                        if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                    }
                }
                if q.isEmpty, !nearby.isEmpty {
                    Section("In the photos around this one") {
                        ForEach(nearby.compactMap { catalog.person($0) }) { row($0) }
                    }
                }
                Section(q.isEmpty ? "Everyone" : "Matches") {
                    ForEach(catalog.people.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }.prefix(400)) { row($0) }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find or add a person")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { CloseLabel("Cancel") } } }
            .task {
                await catalog.load()
                if let r = try? await EditAPI.get("api/faces/nearby", [URLQueryItem(name: "photo", value: "\(photo)")]) {
                    nearby = (r["people"] as? [[String: Any]] ?? []).compactMap { ($0["tag"] as? NSNumber)?.intValue }
                }
            }
        }
    }

    /// The People family groups new people can go under (tags below People that hold people).
    private var families: [EditCatalog.Entry] {
        guard let root = catalog.peopleRoot else { return [] }
        let personIDs = Set(catalog.people.map(\.id))
        return catalog.tags.filter { $0.parent == root && !personIDs.contains($0.id) }
    }

    private func row(_ p: EditCatalog.Entry) -> some View {
        Button { pick(p); dismiss() } label: {
            HStack(spacing: 12) {
                RemoteImage(path: "face/\(p.id)").frame(width: 34, height: 34).clipShape(Circle())
                Text(p.name).foregroundStyle(.primary)
                Spacer()
                Text(p.count.formatted()).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func make(_ name: String) async {
        making = true
        defer { making = false }
        do {
            let r = try await EditAPI.post("api/faces/person", ["name": name, "parent": family ?? catalog.peopleRoot ?? 0])
            await catalog.load(force: true)
            guard let id = (r["id"] as? NSNumber)?.intValue else { throw EditAPI.Failure(message: "The person was not made.") }
            let entry = catalog.person(id) ?? EditCatalog.Entry(id: id, name: name, full: name, parent: family, count: 0)
            pick(entry)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
