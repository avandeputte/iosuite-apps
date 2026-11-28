import SwiftUI
import UIKit

/// The server's pictures, asked with the app password and kept: a picture never changes (its address is its own), so
/// one fetched once is read from disk from then on, also without a connection.
actor PhotoStore {
    static let shared = PhotoStore()

    private let memory = NSCache<NSString, UIImage>()
    private var running: [String: Task<UIImage?, Never>] = [:]

    private func file(_ key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return Shared.cacheFolder.appendingPathComponent("photo-" + String(safe) + ".jpg")
    }

    func image(_ path: String, small: Bool, credential: DeviceCredential) async -> UIImage? {
        let key = path + (small ? "?size=small" : "")
        if let got = memory.object(forKey: key as NSString) { return got }
        if let task = running[key] { return await task.value }
        let file = file(key)
        let task = Task<UIImage?, Never> {
            if let data = try? Data(contentsOf: file), let img = UIImage(data: data) { return img }
            var req = URLRequest(url: DeviceSignIn.url(credential.base, key))
            credential.authorize(&req)
            guard let (data, resp) = try? await API.session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
                  let img = UIImage(data: data) else { return nil }
            try? data.write(to: file, options: .atomic)
            return img
        }
        running[key] = task
        let img = await task.value
        running[key] = nil
        if let img { memory.setObject(img, forKey: key as NSString) }
        return img
    }
}

/// One of the server's pictures, filling the frame it is given.
struct PhotoView: View {
    @EnvironmentObject private var model: AppModel
    let path: String?
    var small = false
    var fit = false
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
            } else {
                Rectangle().fill(Color(.secondarySystemFill))
                Image(systemName: "fork.knife").font(.title).foregroundStyle(.tertiary)
            }
        }
        .task(id: path) {
            image = nil
            guard let path, let c = model.credential else { return }
            image = await PhotoStore.shared.image(path, small: small, credential: c)
        }
    }
}

extension UIImage {
    /// A JPEG to send: upright, at most `side` pixels on its longest side.
    func jpeg(side: CGFloat = 2400, quality: CGFloat = 0.85) -> Data? {
        let longest = max(size.width, size.height) * scale
        let ratio = min(1, side / max(longest, 1))
        let target = CGSize(width: (size.width * scale * ratio).rounded(), height: (size.height * scale * ratio).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: target))
            draw(in: CGRect(origin: .zero, size: target))
        }.jpegData(compressionQuality: quality)
    }
}

/// The camera, where the device has one.
struct CameraPicker: UIViewControllerRepresentable {
    static var available: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
