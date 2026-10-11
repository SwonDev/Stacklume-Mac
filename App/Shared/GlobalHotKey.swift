import Carbon.HIToolbox

/// Registra un atajo de teclado GLOBAL del sistema (vía Carbon `RegisterEventHotKey`),
/// que funciona aunque la app esté en segundo plano y SIN requerir permiso de
/// Accesibilidad/Monitorización de entrada. Llama a `action` al pulsarlo. Se libera al
/// desasignarse (mantener una referencia viva mientras deba estar activo).
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    private let identifier: EventHotKeyID

    /// - Parameters:
    ///   - keyCode: código de tecla virtual (p. ej. `kVK_ANSI_S`).
    ///   - modifiers: máscara Carbon (`cmdKey`, `controlKey`, `optionKey`, `shiftKey`).
    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        identifier = EventHotKeyID(signature: OSType(0x53544B4D /* 'STKM' */),
                                   id: (keyCode << 16) | modifiers)

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        // El handler debe ser una función C SIN capturas: recupera `self` del userData.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            var received = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                    EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &received) == noErr,
                  received.signature == hotKey.identifier.signature,
                  received.id == hotKey.identifier.id else { return OSStatus(eventNotHandledErr) }
            hotKey.action()
            return noErr
        }, 1, &spec, context, &handlerRef)

        RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
