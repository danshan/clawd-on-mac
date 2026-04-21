import Foundation

enum DashboardHTML {
    static let page: String = {
        let css = loadResource("dashboard", ext: "css") ?? ""
        let js = loadResource("dashboard", ext: "js") ?? ""
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Clawd \u{2014} AI Coding Tools</title>
        <style>
        \(css)
        </style>
        </head>
        <body>
        <aside class="sidebar" id="sidebar"></aside>
        <main class="main-content" id="app"><div class="empty"><span class="spinner"></span> Loading...</div></main>
        <script>
        \(js)
        </script>
        </body>
        </html>
        """
    }()

    private static func loadResource(_ name: String, ext: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "dashboard") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
