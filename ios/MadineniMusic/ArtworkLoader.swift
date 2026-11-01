import SwiftUI
import UIKit
import AVKit

@MainActor
final class ArtworkLoader {
    static let shared = ArtworkLoader()
    private let cache = NSCache<NSURL, UIImage>()
    private var failedAt: [URL: Date] = [:]
    private var requests: [URL: Task<UIImage?, Never>] = [:]
    init() { cache.totalCostLimit = 32 * 1024 * 1024; cache.countLimit = 150 }
    func image(from url: URL) async -> UIImage? {
        if let date = failedAt[url], Date().timeIntervalSince(date) < 60 { return nil }
        if let image = cache.object(forKey: url as NSURL) { return image }
        if let request = requests[url] { return await request.value }
        let request = Task<UIImage?, Never> {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count < 10 * 1024 * 1024, let original = UIImage(data: data) else { return nil }
            return await original.byPreparingThumbnail(ofSize: CGSize(width: 640, height: 640)) ?? original
        }
        requests[url] = request
        let image = await request.value
        requests[url] = nil
        if let image {
            cache.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * 4))
            failedAt[url] = nil
        } else {
            failedAt = failedAt.filter { Date().timeIntervalSince($0.value) < 60 }
            failedAt[url] = Date()
        }
        return image
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor(red: 0.79, green: 0.47, blue: 0.27, alpha: 1)
        view.activeTintColor = .systemOrange
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
