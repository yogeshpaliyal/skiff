import UIKit
import UniformTypeIdentifiers

/**
 * "Skiff" in the share sheet: a page shared from Safari, the IMDb app, Trakt, YouTube… goes to Skiff, which opens it on
 * the TV (as sharing to Skiff does on Android). The page's link (and its title, as the subject) are handed to the app
 * as skiff://share?text=…&subject=….
 */
final class ShareViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await handle() }
    }

    private func handle() async {
        var text: [String] = []
        var subject: String?
        for item in extensionContext?.inputItems as? [NSExtensionItem] ?? [] {
            if subject == nil, let title = item.attributedContentText?.string, !title.isEmpty { subject = title }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    text.append(url.absoluteString)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let s = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    text.append(s)
                }
            }
        }
        var c = URLComponents()
        c.scheme = "skiff"
        c.host = "share"
        c.queryItems = [URLQueryItem(name: "text", value: text.joined(separator: "\n"))]
            + (subject.map { [URLQueryItem(name: "subject", value: $0)] } ?? [])
        if let url = c.url { open(url) }
        extensionContext?.completeRequest(returningItems: nil)
    }

    /** A share extension can't open its app directly: the responder chain reaches the application, which can. */
    private func open(_ url: URL) {
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication {
                app.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = r.next
        }
    }
}
