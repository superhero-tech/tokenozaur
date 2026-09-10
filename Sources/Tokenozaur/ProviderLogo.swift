import AppKit
import TokenozaurCore

enum ProviderLogo {
  static func image(for provider: Provider) -> NSImage {
    switch provider {
    case .codex: return codex
    case .claude: return claude
    }
  }

  private static let codex: NSImage = {
    if let applicationURL = applicationURL(
      bundleIdentifier: "com.openai.codex",
      fallbackPath: "/Applications/ChatGPT.app"
    ), let resourcesURL = Bundle(url: applicationURL)?.resourceURL {
      let preferredAssets = [
        "icon-chatgpt.icns",
        "app.icns",
        "electron.icns",
      ]
      for asset in preferredAssets {
        if let image = NSImage(contentsOf: resourcesURL.appendingPathComponent(asset)) {
          return image
        }
      }
      return NSWorkspace.shared.icon(forFile: applicationURL.path)
    }
    return fallbackImage(description: "Codex")
  }()

  private static let claude: NSImage = {
    if let applicationURL = applicationURL(
      bundleIdentifier: "com.anthropic.claudefordesktop",
      fallbackPath: "/Applications/Claude.app"
    ) {
      return NSWorkspace.shared.icon(forFile: applicationURL.path)
    }
    return fallbackImage(description: "Claude Code")
  }()

  private static func applicationURL(bundleIdentifier: String, fallbackPath: String) -> URL? {
    if let discovered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    {
      return discovered
    }
    let fallback = URL(fileURLWithPath: fallbackPath)
    return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
  }

  private static func fallbackImage(description: String) -> NSImage {
    NSImage(
      systemSymbolName: "terminal.fill",
      accessibilityDescription: description
    ) ?? NSImage(size: NSSize(width: 26, height: 26))
  }
}
