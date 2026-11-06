import Carbon

/// Global hotkeys via Carbon — works without Accessibility permission.
@MainActor
enum Hotkeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false

    /// Returns false when the combination is taken by the system or another app.
    @discardableResult
    static func register(keyCode: Int, _ handler: @escaping () -> Void) -> Bool {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &id)
                MainActor.assumeIsolated { Hotkeys.handlers[id.id]?() } // Carbon delivers on the main thread
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        let id = UInt32(handlers.count + 1)
        handlers[id] = handler
        var ref: EventHotKeyRef?
        return RegisterEventHotKey(UInt32(keyCode), UInt32(controlKey | optionKey), EventHotKeyID(signature: OSType(0x4848_4B59), id: id),
                                   GetApplicationEventTarget(), 0, &ref) == noErr
    }
}
