/// Tracks a right-Control press/release without consuming Control shortcuts.
public struct RightControlTap {
    // NX_DEVICERCTLKEYMASK / NX_DEVICELCTLKEYMASK from IOLLEvent.h.
    public static let rightControl: UInt = 0x2000
    private static let disallowed: UInt = 0x1 | (1 << 17) | (1 << 19) | (1 << 20) | (1 << 23)
    private var held = false
    private var eligible = false
    public init() {}
    public mutating func cancel() { eligible = false }
    public mutating func reset() { held = false; eligible = false }
    public mutating func flagsChanged(keyCode: UInt16, flags: UInt) -> Bool {
        let rightDown = flags & Self.rightControl != 0
        let clean = flags & Self.disallowed == 0
        guard keyCode == 62 else {
            cancel()
            if !rightDown { held = false }
            return false
        }
        if rightDown {
            if !held { eligible = clean }
            else if !clean { cancel() }
            held = true
            return false
        }
        let toggle = held && eligible && clean
        reset()
        return toggle
    }
}
