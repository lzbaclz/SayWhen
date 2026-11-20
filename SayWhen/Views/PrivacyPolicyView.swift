import SwiftUI
import WebKit

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let file = Bundle.main.url(forResource: "privacy", withExtension: "html") {
                    LocalPolicyPage(file: file)
                } else {
                    ContentUnavailableView("未能打开隐私政策", systemImage: "doc.text")
                }
            }
            .navigationTitle("隐私政策")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Link("技术支持", destination: URL(string: "https://lzbaclz.github.io/SayWhen/support.html")!)
                    Spacer()
                    Link("在线隐私政策", destination: URL(string: "https://lzbaclz.github.io/SayWhen/privacy.html")!)
                }
            }
        }
    }
}

private struct LocalPolicyPage: UIViewRepresentable {
    let file: URL

    func makeUIView(context: Context) -> WKWebView {
        let settings = WKWebViewConfiguration()
        settings.websiteDataStore = .nonPersistent()
        settings.defaultWebpagePreferences.allowsContentJavaScript = false
        let page = WKWebView(frame: .zero, configuration: settings)
        page.loadFileURL(file, allowingReadAccessTo: file)
        return page
    }

    func updateUIView(_ page: WKWebView, context: Context) {}
}
