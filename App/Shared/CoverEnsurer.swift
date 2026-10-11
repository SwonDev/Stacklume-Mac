import Foundation
import CryptoKit
import SwiftData
import StacklumeCore

/// Punto ÚNICO para «asegurar la portada» de un enlace que no tiene imagen, reutilizado
/// por el alta ([[LinkIngest]]), el enriquecido por lote/colección (`AIBatchEnricher`) y
/// la barra de lote. Cadena de respaldo, de lo más barato a lo más caro:
///
/// 1. `PageImageFinder`: `og:image`/`twitter:image` o la imagen «hero» del `<img>` del HTML.
/// 2. `PageSnapshotService`: captura del hero RENDERIZADO (SPAs/`canvas`/WebGL que no
///    exponen imágenes en el HTML, p. ej. StemStudio). Es lo más caro (abre un WKWebView),
///    así que va serializado (una a la vez) y se OMITE en hosts con muro de login (X), donde
///    saldría la pantalla de inicio de sesión en vez del contenido.
///
/// Solo actúa si al enlace le FALTA portada (no pisa una `imageURL` ni una portada
/// personalizada que ya tenga). 100 % local. No usa el modelo LLM.
@MainActor
enum CoverEnsurer {

    /// Hosts donde una captura a ciegas saldría mal (muro de login / contenido tras auth):
    /// para ellos solo se intenta la imagen del HTML, nunca el snapshot.
    private static let noSnapshotHosts: Set<String> = [
        "x.com", "twitter.com", "mobile.twitter.com", "t.co"
    ]

    static func allowsSnapshot(of rawURL: String) -> Bool {
        let host = URL(string: rawURL)?.host()?.lowercased()
            .replacingOccurrences(of: "www.", with: "") ?? ""
        return !noSnapshotHosts.contains(host)
    }

    /// ¿Hay una referencia de portada o una portada personalizada? No comprueba sus bytes.
    static func hasCover(_ link: Bookmark) -> Bool {
        if let url = link.imageURL, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return CustomCoverStore.shared.has(link.id)
    }

    /// Recupera los bytes de la referencia existente sin cambiarla, ni sustituirla por
    /// una captura. El reintento explícito levanta únicamente el fallo de esta URL.
    static func recoverReference(for link: Bookmark, retry: Bool = false) async -> CoverRecoveryPolicy.Result {
        if Task.isCancelled { return .cancelled }
        guard link.modelContext != nil, link.deletedAt == nil, link.fileKind == nil else { return .unavailable }
        if CustomCoverStore.shared.has(link.id) { return .stored }
        let reference = link.imageURL
        let page = link.url
        let owner = link.modelContext
        func canRetrieve() -> Bool {
            !Task.isCancelled && link.modelContext === owner && link.deletedAt == nil && link.fileKind == nil
                && link.url == page && link.imageURL == reference && !CustomCoverStore.shared.has(link.id)
        }
        let result = await CoverRecoveryPolicy.recover(reference: reference, stored: { url in
            guard canRetrieve() else { return false }
            let stored = await SecureImageCache.shared.storedImage(for: url) != nil
            return canRetrieve() && stored
        }, acquire: { url in
            guard canRetrieve() else { return false }
            if retry { SecureImageCache.shared.retry(for: url) }
            let acquired = await SecureImageCache.shared.image(for: url) != nil
            return canRetrieve() && acquired
        })
        if Task.isCancelled { return .cancelled }
        return canRetrieve() ? result : .unavailable
    }

    /// Obtiene una imagen validada de la página pública y la guarda lateralmente.
    /// Conserva la referencia fallida y evita capturar pantallas de acceso o error.
    @discardableResult
    static func recoverFromPage(for link: Bookmark, in context: ModelContext, retry: Bool = false) async -> Bool {
        guard !Task.isCancelled, link.modelContext != nil, link.deletedAt == nil, link.fileKind == nil,
              let reference = link.imageURL,
              !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !CustomCoverStore.shared.has(link.id) else { return false }
        let page = link.url
        let owner = link.modelContext
        guard let candidate = await PageImageFinder.bestImageURL(for: page, retry: retry),
              !Task.isCancelled, link.modelContext === owner, link.deletedAt == nil, link.fileKind == nil,
              link.imageURL == reference, link.url == page,
              !CustomCoverStore.shared.has(link.id),
              let imageURL = URL(string: candidate),
              let bytes = await SecureImageCache.shared.cachedBytesForSearch(for: imageURL),
              !Task.isCancelled, link.modelContext === owner, link.deletedAt == nil, link.fileKind == nil,
              link.imageURL == reference, link.url == page,
              !CustomCoverStore.shared.has(link.id),
              CustomCoverStore.shared.restore(bytes, for: link.id) else { return false }
        guard let jpeg = CustomCoverStore.shared.coverData(for: link.id) else {
            CustomCoverStore.shared.remove(for: link.id)
            return false
        }
        let digest = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
        let provenance = CoverRecoveryProvenanceStore.Entry(referenceURL: reference,
            pageURL: page, recoveredImageURL: candidate, recoveredAt: Date(), coverJPEGDigest: digest)
        guard CoverRecoveryProvenanceStore.shared.record(provenance, for: link.id) else {
            CustomCoverStore.shared.remove(for: link.id)
            return false
        }
        link.updatedAt = Date()
        context.saveLogging()
        return true
    }

    /// Asegura una portada para `link`. Devuelve `true` si adquirió bytes o añadió una.
    /// `allowSnapshot=false` evita la captura (cara) en flujos donde no convenga.
    @discardableResult
    static func ensure(for link: Bookmark, in context: ModelContext, allowSnapshot: Bool = true,
                       useCachedSnapshot: Bool = false, retry: Bool = false) async -> Bool {
        guard !Task.isCancelled, link.modelContext != nil, link.deletedAt == nil, link.fileKind == nil,
              !CustomCoverStore.shared.has(link.id) else { return false }
        let page = link.url
        let reference = link.imageURL
        let owner = link.modelContext
        func canApply() -> Bool {
            !Task.isCancelled && link.modelContext === owner && link.deletedAt == nil && link.fileKind == nil
                && link.url == page && link.imageURL == reference && !CustomCoverStore.shared.has(link.id)
        }
        if let reference,
           !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let result = await recoverReference(for: link, retry: retry)
            guard canApply() else { return false }
            if result == .acquired { return true }
            if result == .unavailable { return await recoverFromPage(for: link, in: context, retry: retry) }
            return false
        }

        // 1) Imagen del HTML (og:image / `<img>` hero): rápida y «limpia».
        if let found = await PageImageFinder.bestImageURL(for: page, retry: retry),
           canApply() {
            link.imageURL = found
            link.updatedAt = Date()
            context.saveLogging()
            return true
        }

        // 2) Captura del hero renderizado (SPAs/canvas), salvo hosts con muro de login.
        guard canApply(), allowSnapshot, allowsSnapshot(of: page) else { return false }

        if let shot = await PageSnapshotService.snapshot(of: page, useCached: useCachedSnapshot),
           canApply(),
           CustomCoverStore.shared.set(shot, for: link.id) {
            link.updatedAt = Date()
            context.saveLogging()
            return true
        }
        return false
    }
}
