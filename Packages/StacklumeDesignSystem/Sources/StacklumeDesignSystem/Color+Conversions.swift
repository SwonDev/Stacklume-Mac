import SwiftUI

/// Color en espacio OKLCH (igual que el CSS del Stacklume original).
/// Se convierte a `Color` pasando por sRGB lineal, que SwiftUI codifica a gamma.
public struct OKLCH: Sendable, Hashable {
    public var l: Double   // luminosidad 0...1
    public var c: Double   // croma
    public var h: Double   // tono en grados

    public init(_ l: Double, _ c: Double, _ h: Double) {
        self.l = l
        self.c = c
        self.h = h
    }

    /// `Color` SwiftUI equivalente.
    public var color: Color {
        let (r, g, b) = OKLCH.toLinearSRGB(l: l, c: c, h: h)
        return Color(.sRGBLinear, red: r, green: g, blue: b, opacity: 1)
    }

    /// Conversión OKLCH → OKLab → LMS → sRGB lineal (matriz estándar de Björn Ottosson).
    static func toLinearSRGB(l: Double, c: Double, h: Double) -> (Double, Double, Double) {
        let hr = h * .pi / 180.0
        let a = c * cos(hr)
        let b = c * sin(hr)

        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b

        let l3 = l_ * l_ * l_
        let m3 = m_ * m_ * m_
        let s3 = s_ * s_ * s_

        var r =  4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3
        var g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3
        var bb = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3

        r = min(max(r, 0), 1)
        g = min(max(g, 0), 1)
        bb = min(max(bb, 0), 1)
        return (r, g, bb)
    }
}

public extension Color {
    /// Inicializa un `Color` desde una cadena hex (#RGB o #RRGGBB).
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let r, g, b: UInt64
        switch cleaned.count {
        case 3:
            r = (value >> 8 & 0xF) * 17
            g = (value >> 4 & 0xF) * 17
            b = (value & 0xF) * 17
        case 6:
            r = value >> 16 & 0xFF
            g = value >> 8 & 0xFF
            b = value & 0xFF
        default:
            r = 110; g = 113; b = 134   // gris neutro de reserva
        }

        self.init(.sRGB,
                  red: Double(r) / 255.0,
                  green: Double(g) / 255.0,
                  blue: Double(b) / 255.0,
                  opacity: 1)
    }

    /// Color estable y agradable derivado de un texto (p. ej. el host de un enlace):
    /// el mismo texto produce SIEMPRE el mismo color, repartido por el círculo
    /// cromático. Pensado como respaldo para tiles sin imagen ni color de plataforma,
    /// para que un mural quede como un mosaico variado y no como un muro monótono.
    /// Usa OKLCH (luminosidad y croma fijos) para tonos perceptualmente uniformes,
    /// coherentes con la paleta del sistema.
    init(seed: String) {
        // Hash determinista FNV-1a: estable entre lanzamientos (a diferencia de
        // `hashValue`, que se aleatoriza por proceso y daría colores cambiantes).
        var hash: UInt64 = 1469598103934665603
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        let hue = Double(hash % 360)
        self = OKLCH(0.62, 0.13, hue).color
    }
}
