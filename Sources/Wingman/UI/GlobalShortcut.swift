import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// A key combination, e.g. ⌃⌥⌘R.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// NSEvent.ModifierFlags raw value (command, option, control, shift only).
    var modifiers: UInt
    /// How the key itself reads, e.g. "R" or "F5".
    var key: String

    /// Start/stop recording: ⌃⌥⌘R.
    static let `default` = Shortcut(
        keyCode: UInt32(kVK_ANSI_R),
        modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue,
        key: "R")

    /// Mute/unmute Wingman: ⌃⌥M.
    static let defaultMute = Shortcut(
        keyCode: UInt32(kVK_ANSI_M),
        modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue,
        key: "M")

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + key
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// Builds a shortcut from a key press, if it has a modifier other than Shift
    /// (plain letters would fire while typing).
    init?(event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !mods.subtracting(.shift).isEmpty else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = mods.rawValue
        key = Self.name(for: event)
    }

    init(keyCode: UInt32, modifiers: UInt, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    private static func name(for event: NSEvent) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = special[Int(event.keyCode)] { return name }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

/// A system-wide shortcut that works from any app. Uses Carbon's hot-key API,
/// which needs no Accessibility or Input Monitoring permission. Several can
/// exist (record, mute); one shared handler dispatches by hot-key ID.
@MainActor
@Observable
final class GlobalShortcut {
    let name: String
    let defaultShortcut: Shortcut?
    private(set) var shortcut: Shortcut?
    /// Set when macOS refuses to register the combination. (It can't tell
    /// whether another app uses the same one: both would get it.)
    private(set) var conflict = false
    var action: (() -> Void)?

    private let id: UInt32
    private let defaultsKey: String
    private var hotKey: EventHotKeyRef?

    private static var registry: [UInt32: GlobalShortcut] = [:]
    private static var handlerInstalled = false

    init(id: UInt32, name: String, defaultsKey: String, defaultShortcut: Shortcut?) {
        self.id = id
        self.name = name
        self.defaultsKey = defaultsKey
        self.defaultShortcut = defaultShortcut
        if let data = UserDefaults.standard.data(forKey: defaultsKey) {
            shortcut = try? JSONDecoder().decode(Shortcut?.self, from: data)
        } else {
            shortcut = defaultShortcut
        }
        Self.registry[id] = self
        Self.installHandler()
        register()
    }

    /// Every registered shortcut, e.g. to check a new combination for clashes.
    static var all: [GlobalShortcut] { registry.values.sorted { $0.id < $1.id } }

    /// Changes the shortcut; nil turns it off.
    func set(_ new: Shortcut?) {
        shortcut = new
        UserDefaults.standard.set(try? JSONEncoder().encode(new), forKey: defaultsKey)
        register()
    }

    /// Pauses every shortcut while a new one is being typed, so pressing an
    /// existing combination records it instead of triggering its action.
    static func suspendAll() { registry.values.forEach { $0.unregister() } }
    static func resumeAll() { registry.values.forEach { $0.register() } }

    private func register() {
        unregister()
        conflict = false
        guard let shortcut else { return }
        let hotKeyID = EventHotKeyID(signature: OSType(0x57474D4E), id: id)  // "WGMN"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKey)
        conflict = status != noErr
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            guard let event,
                  GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID) == noErr
            else { return noErr }
            let id = hotKeyID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalShortcut.registry[id]?.action?() } }
            return noErr
        }, 1, &type, nil, nil)
    }
}

/// A field that shows the current shortcut and records a new one when clicked.
/// While it waits for keys, every key press goes to it and the shortcuts are
/// paused, so that state ends when the field goes away and only one field
/// waits at a time.
struct ShortcutRecorder: View {
    let shortcut: GlobalShortcut
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?
    @State private var token = UUID()
    /// The field waiting for keys, if any, and how to stop it.
    @MainActor private static var active: (token: UUID, stop: () -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                Text(recording ? "Type a shortcut…" : (shortcut.shortcut?.display ?? "None"))
                    .monospaced()
                    .frame(minWidth: 120)
            }
            .help("Click, then press the key combination you want. Esc cancels.")
            if shortcut.shortcut != nil && !recording {
                Button("Turn Off") {
                    hint = nil
                    shortcut.set(nil)
                }
            }
            if shortcut.shortcut != shortcut.defaultShortcut && !recording, let fallback = shortcut.defaultShortcut {
                Button("Reset") {
                    if let other = clash(with: fallback) {
                        hint = "The default is now used for “\(other.name)”. Change that one first."
                    } else {
                        hint = nil
                        shortcut.set(fallback)
                    }
                }
            }
        }
        .onDisappear {
            if recording { stopRecording() }
            hint = nil  // it may no longer be true when Settings opens again
        }
        if let hint {
            Text(hint).font(.caption).foregroundStyle(.orange)
        } else if shortcut.conflict {
            Text("macOS didn't accept this shortcut. Pick a different one.")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private func clash(with new: Shortcut) -> GlobalShortcut? {
        GlobalShortcut.all.first { $0 !== shortcut && $0.shortcut.map(Self.sameKeys(new)) == true }
    }

    private func startRecording() {
        if let other = Self.active, other.token != token { other.stop() }
        hint = nil
        recording = true
        Self.active = (token, { stopRecording() })
        GlobalShortcut.suspendAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
            } else if let new = Shortcut(event: event) {
                if let other = clash(with: new) {
                    hint = "Already used for “\(other.name)”. Pick a different combination."
                } else {
                    shortcut.set(new)
                    stopRecording()
                }
            } else {
                hint = "Include ⌘, ⌥ or ⌃ so the shortcut doesn't fire while you type."
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        if Self.active?.token == token { Self.active = nil }
        GlobalShortcut.resumeAll()
    }

    private static func sameKeys(_ a: Shortcut) -> (Shortcut) -> Bool {
        { b in a.keyCode == b.keyCode && a.modifiers == b.modifiers }
    }
}
