import SwiftUI

/// Tokens de diseño del sistema (espaciado y geometría).
public enum DesignSystem {
    /// Radio de esquina por defecto para tarjetas y contenedores.
    public static let cornerRadius: CGFloat = 12

    public enum Spacing {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let sm: CGFloat = 12
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 24
        public static let xl: CGFloat = 32
    }
}
