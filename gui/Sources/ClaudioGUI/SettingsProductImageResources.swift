import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioSettingsPresentation

@MainActor
func makeSettingsProductImages() -> SettingsProductImages {
    var images: [String: NSImage] = [:]
    for name in [
        "claude-light", "codex-light", "codex-dark", "workbuddy-light",
        "opencode-light", "kimi-code-light",
    ] {
        if let url = hostIconResourceBundle.url(
            forResource: name, withExtension: "png", subdirectory: "SettingsHostIcons"),
            let image = NSImage(contentsOf: url)
        {
            image.isTemplate = false
            images[name] = SettingsProductImages.normalized(image)
        }
    }
    return SettingsProductImages { host, dark in
        let prefix: String
        switch host {
        case .claudeCode: prefix = "claude"
        case .codex: prefix = "codex"
        case .workBuddy: prefix = "workbuddy"
        case .opencode: prefix = "opencode"
        case .kimiCode: prefix = "kimi-code"
        default: return nil
        }
        return images[prefix + (prefix == "codex" && dark ? "-dark" : "-light")]
    }
}
