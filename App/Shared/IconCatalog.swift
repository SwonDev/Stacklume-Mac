import Foundation

/// Catálogo amplio de SF Symbols para personalizar categorías, proyectos y más.
enum IconCatalog {
    static let all: [String] = [
        // General / organización
        "folder.fill", "tray.full.fill", "archivebox.fill", "shippingbox.fill",
        "tag.fill", "bookmark.fill", "star.fill", "heart.fill", "flag.fill", "pin.fill",
        "list.bullet.rectangle.fill", "square.grid.2x2.fill", "rectangle.stack.fill",
        // Desarrollo / tech
        "chevron.left.forwardslash.chevron.right", "curlybraces", "terminal.fill",
        "cpu.fill", "memorychip.fill", "externaldrive.fill", "server.rack",
        "laptopcomputer", "desktopcomputer", "keyboard.fill", "network",
        "ant.fill", "hammer.fill", "wrench.and.screwdriver.fill", "gearshape.fill",
        // Diseño / creatividad
        "paintpalette.fill", "paintbrush.fill", "pencil.and.outline", "ruler.fill",
        "highlighter", "camera.fill", "photo.fill", "wand.and.stars", "scribble.variable",
        "theatermasks.fill", "sparkles",
        // Multimedia / ocio
        "play.rectangle.fill", "film.fill", "music.note", "headphones", "mic.fill",
        "gamecontroller.fill", "dice.fill", "guitars.fill", "tv.fill", "radio.fill",
        // Lectura / trabajo
        "book.fill", "books.vertical.fill", "newspaper.fill", "doc.text.fill",
        "graduationcap.fill", "briefcase.fill", "case.fill", "calendar", "checklist",
        "lightbulb.fill", "brain.head.profile",
        // Compras / dinero
        "cart.fill", "bag.fill", "creditcard.fill", "dollarsign.circle.fill",
        "giftcard.fill", "tag.circle.fill", "chart.line.uptrend.xyaxis",
        // Vida / lugares
        "house.fill", "building.2.fill", "globe", "map.fill", "location.fill",
        "airplane", "car.fill", "leaf.fill", "flame.fill", "drop.fill", "bolt.fill",
        "cup.and.saucer.fill", "fork.knife", "pawprint.fill", "figure.run", "cross.case.fill",
        // Comunicación / social
        "bubble.left.and.bubble.right.fill", "envelope.fill", "phone.fill", "person.2.fill",
        "bell.fill", "megaphone.fill",

        // ── Ampliación: MUCHA más variedad para que no se repitan iconos en bibliotecas con
        //    muchas colecciones del mismo tema (p. ej. varias de IA). Los nombres se VALIDAN en
        //    runtime (ver CollectionIconSuggester) y se descartan los que no existan en esta
        //    versión de macOS, así que ampliar es seguro. ──
        // IA / ML / agentes (variedad para distinguir colecciones de IA entre sí)
        "brain", "cpu", "memorychip", "sparkle", "wand.and.rays", "atom", "function",
        "point.3.connected.trianglepath.dotted", "point.3.filled.connected.trianglepath.dotted",
        "circle.hexagongrid.fill", "rays", "bolt.horizontal.fill", "gearshape.2.fill",
        // 3D / modelado
        "cube", "cube.transparent", "square.stack.3d.up.fill", "square.stack.3d.down.right.fill",
        "pyramid.fill", "view.3d", "rotate.3d",
        // Imagen / visión
        "photo.stack.fill", "photo.on.rectangle.angled", "camera.aperture", "camera.macro",
        "eye.fill", "paintbrush.pointed.fill", "square.and.pencil", "rectangle.and.pencil.and.ellipsis",
        // Sonido / voz / TTS
        "waveform", "waveform.circle.fill", "music.mic", "speaker.wave.3.fill", "ear.fill",
        // Desarrollo / código / herramientas
        "curlybraces.square.fill", "ladybug.fill", "wrench.adjustable.fill", "slider.horizontal.3",
        "chevron.left.forwardslash.chevron.right.square.fill",
        // Bases de datos / almacenamiento
        "cylinder.fill", "cylinder.split.1x2.fill", "tablecells.fill", "internaldrive.fill",
        // Deploy / nube / red / API
        "icloud.fill", "cloud.fill", "paperplane.fill", "arrow.up.forward.app.fill",
        "antenna.radiowaves.left.and.right", "link", "globe.americas.fill", "macwindow",
        // Diseño / UI
        "swatchpalette.fill", "pencil.and.ruler.fill", "rectangle.3.group.fill", "square.grid.3x3.fill",
        "paintbrush.pointed", "eyedropper.halffull",
        // Juegos / retro
        "dpad.fill", "formfitting.gamecontroller.fill", "arcade.stick.console.fill",
        // SO / dispositivos
        "iphone", "ipad", "applewatch", "display", "apple.logo", "macpro.gen3.fill",
        // Tipografía / texto / lectura
        "textformat", "textformat.size", "character", "a.square.fill", "doc.richtext.fill",
        // Comunicación / social extra
        "person.3.fill", "quote.bubble.fill", "at",
        // Varios útiles
        "puzzlepiece.fill", "shippingbox.circle.fill", "lightbulb.max.fill", "key.fill",
        "lock.fill", "shield.lefthalf.filled", "magnifyingglass", "binoculars.fill",
    ]
}
