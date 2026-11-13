import SwiftUI

struct InfoPanel: View {
    let photo: Int
    var favorite = false
    @State private var info: PhotoInfo?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if let info {
                    if let t = info.title { Text(t).font(.title3.bold()) }
                    if info.rating > 0 { Text(String(repeating: "★", count: min(info.rating, 5))).foregroundStyle(.yellow) }
                    Label(favorite ? "In your favorites · hold select to remove" : "Hold select to add to your favorites",
                          systemImage: favorite ? "heart.fill" : "heart")
                        .font(.caption).foregroundStyle(favorite ? .pink : .secondary)
                    row("calendar", info.when)
                    row("mappin.and.ellipse", info.place)
                    row("person.2.fill", info.people.isEmpty ? nil : info.people.joined(separator: ", "))
                    row("tag.fill", info.tags.isEmpty ? nil : info.tags.joined(separator: ", "))
                    row("folder.fill", info.folder)
                    row("camera.fill", info.camera)
                    row("camera.aperture", info.settings)
                    row("doc.fill", info.file)
                } else {
                    ProgressView()
                }
            }
            .padding(50)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 640)
        .background(.ultraThinMaterial)
        .task(id: photo) {
            info = nil
            info = await PhotoInfo.load(photo)
        }
    }

    @ViewBuilder private func row(_ icon: String, _ text: String?) -> some View {
        if let text {
            HStack(alignment: .top, spacing: 20) {
                Image(systemName: icon).frame(width: 40).foregroundStyle(.secondary)
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
