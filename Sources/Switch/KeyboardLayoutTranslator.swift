import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Thread-safe snapshot of the active Unicode keyboard layout.
///
/// CGEvent's Unicode string is associated when the event is created; changing
/// its modifier flags does not translate it again. The event-tap thread instead
/// uses this immutable layout snapshot with UCKeyTranslate, preserving Shift
/// (needed for AZERTY digits) while intentionally excluding Command, Option,
/// and Control from printable picker commands.
final class KeyboardLayoutTranslator {
    static let shared = KeyboardLayoutTranslator()

    private let lock = NSLock()
    private var layoutData: Data?

    private init() {}

    /// TIS access stays on the main thread. The event tap only reads the copied
    /// Data under a short lock and never touches TSM/NSEvent.
    func refresh() {
        assert(Thread.isMainThread)
        let current = Self.currentLayoutData()
        lock.lock()
        layoutData = current
        lock.unlock()
    }

    func character(for keyCode: CGKeyCode, shift: Bool) -> Character? {
        lock.lock()
        let snapshot = layoutData
        lock.unlock()
        guard let snapshot else { return nil }
        return Self.character(
            for: keyCode,
            shift: shift,
            layoutData: snapshot,
            keyboardType: UInt32(LMGetKbdType())
        )
    }

    static func character(
        for keyCode: CGKeyCode,
        shift: Bool,
        layoutData: Data,
        keyboardType: UInt32
    ) -> Character? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let modifierState = shift ? UInt32(shiftKey >> 8) : 0
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                base,
                keyCode,
                UInt16(kUCKeyActionDown),
                modifierState,
                keyboardType,
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length).first
    }

    static func currentLayoutData() -> Data? {
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let data = layoutData(from: source) {
            return data
        }
        // IMEs may not expose Unicode layout data. Fall back to their associated
        // ASCII-capable layout so raw pinyin/Latin filtering remains available.
        if let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
            return layoutData(from: source)
        }
        return nil
    }

    static func layoutData(from source: TISInputSource) -> Data? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let cfData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        return Data(cfData as Data)
    }
}
