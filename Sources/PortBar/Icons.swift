import AppKit

/// Brand marks from Simple Icons (CC0), tinted with the brand color. Near-black brands become templates so they follow the menu theme.
enum Icons {
    static let brands: [String: (slug: String, hex: UInt32)] = [
        "Laravel": ("laravel", 0xFF2D20), "Reverb": ("laravel", 0xFF2D20), "Horizon": ("laravel", 0xFF2D20), "Octane": ("laravel", 0xFF2D20),
        "Vite": ("vite", 0x9135FF), "Next.js": ("nextdotjs", 0), "Astro": ("astro", 0xBC52EE), "Nuxt": ("nuxt", 0x00DC82),
        "Remix": ("remix", 0), "SvelteKit": ("svelte", 0xFF3E00), "Mintlify": ("mintlify", 0x18E299), "Docusaurus": ("docusaurus", 0x3ECC5F),
        "VitePress": ("vitepress", 0x5C73E7), "Storybook": ("storybook", 0xFF4785), "Webpack": ("webpack", 0x8DD6F9),
        "Gatsby": ("gatsby", 0x663399), "Expo": ("expo", 0), "Wrangler": ("cloudflareworkers", 0xF38020),
        "Playwright": ("playwright", 0x2EAD33), "Django": ("django", 0x44B78B), "Uvicorn": ("fastapi", 0x009688),
        "Gunicorn": ("gunicorn", 0x499848), "Flask": ("flask", 0x3BABC3), "Jupyter": ("jupyter", 0xF37626),
        "Rails": ("rubyonrails", 0xD30001), "Hugo": ("hugo", 0xFF4088), "Jekyll": ("jekyll", 0xCC0000), "MkDocs": ("materialformkdocs", 0x526CFE),
        "Postgres": ("postgresql", 0x4169E1), "Redis": ("redis", 0xFF4438), "MySQL": ("mysql", 0x4479A1), "MongoDB": ("mongodb", 0x47A248),
        "Meilisearch": ("meilisearch", 0xFF5CAA), "MinIO": ("minio", 0xC72E49), "Ollama": ("ollama", 0), "Caddy": ("caddy", 0x1F88C0),
        "Nginx": ("nginx", 0x009639), "PHP-FPM": ("php", 0x777BB4), "PHP": ("php", 0x777BB4), "Node": ("nodedotjs", 0x5FA04E),
        "Bun": ("bun", 0), "Deno": ("deno", 0), "Python": ("python", 0x3776AB), "Python http.server": ("python", 0x3776AB),
        "Ruby": ("ruby", 0xCC342D), "Java": ("openjdk", 0), "dotnet": ("dotnet", 0x512BD4), "Elixir": ("elixir", 0x4B275F),
        "Docker": ("docker", 0x2496ED),
    ]

    private static var cache: [String: NSImage] = [:]

    static func image(for stack: String) -> NSImage {
        if let hit = cache[stack] { return hit }
        let made = brand(stack) ?? fallback()
        cache[stack] = made
        return made
    }

    private static func brand(_ stack: String) -> NSImage? {
        guard let (slug, hex) = brands[stack],
              let url = Bundle.main.url(forResource: slug, withExtension: "svg", subdirectory: "icons"),
              let svg = NSImage(contentsOf: url) else { return nil }
        let size = NSSize(width: 16, height: 16)
        let template = hex == 0
        let color = NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        let img = NSImage(size: size, flipped: false) { rect in
            svg.draw(in: rect)
            (template ? NSColor.black : color).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        img.isTemplate = template
        return img
    }

    private static func fallback() -> NSImage {
        let img = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) ?? NSImage()
        img.isTemplate = true
        return img
    }
}
