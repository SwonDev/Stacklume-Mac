import SwiftUI
#if canImport(UIKit)
import UIKit
/// Imagen de plataforma: `UIImage` en iOS, `NSImage` en macOS.
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#endif

public extension Image {
    /// Crea una `Image` de SwiftUI desde una imagen de plataforma, sin que el
    /// código de UI tenga que ramificar por plataforma.
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #elseif canImport(AppKit)
        self.init(nsImage: platformImage)
        #endif
    }
}
