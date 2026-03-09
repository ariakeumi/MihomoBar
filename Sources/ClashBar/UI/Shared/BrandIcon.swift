import AppKit

enum BrandIcon {
    private static let resourceSubdirectory = "Brand"

    static let image: NSImage? = {
        BrandIcon.load(resourceName: "mihomobar", resourceExtension: "icns")
    }()

    static let statusItemImage: NSImage? = {
        BrandIcon.load(resourceName: "clashbar-icon", resourceExtension: "png")
    }()

    private static func load(resourceName: String, resourceExtension: String) -> NSImage? {
        for bundle in AppResourceBundleLocator.candidateBundles() {
            if let url = bundle.url(
                forResource: resourceName,
                withExtension: resourceExtension,
                subdirectory: resourceSubdirectory), let image = NSImage(contentsOf: url)
            {
                return image
            }

            if let url = bundle.url(forResource: resourceName, withExtension: resourceExtension),
               let image = NSImage(contentsOf: url)
            {
                return image
            }
        }
        return nil
    }
}
