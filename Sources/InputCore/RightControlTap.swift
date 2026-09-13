/// Tracks a right-Control press/release without consuming Control shortcuts.
public struct RightControlTap {
    // NX_DEVICERCTLKEYMASK / NX_DEVICELCTLKEYMASK from IOLLEvent.h.
    public static let rightControl: UInt = 0x2000
    private static let disallowed: UInt = 0x1 | (1 << 17) | (1 << 19) | (1 << 20) | (1 << 23)
    private var leftHeld = false
    private var held = false
    private var eligible = false
    public init() {}
    public mutating func cancel() { eligible = false }
    public mutating func reset() { leftHeld = false; held = false; eligible = false }
    public mutating func flagsChanged(keyCode: UInt16, flags: UInt) -> Bool {
        let controlDown = flags & ((1 << 18) | Self.rightControl | 0x1) != 0
        let sideBits = flags & (Self.rightControl | 0x1)
        if keyCode == 59 {
            leftHeld = sideBits != 0 ? flags & 0x1 != 0 : controlDown && !leftHeld
        } else if !controlDown {
            leftHeld = false
        }
        // IMK may forward only device-independent flags: use keyCode for the
        // side and the aggregate Control bit for its state in that case.
        let rightDown = sideBits != 0 ? flags & Self.rightControl != 0
            : controlDown && (!leftHeld || !held)
        let clean = !leftHeld && flags & Self.disallowed == 0
        guard keyCode == 62 else {
            cancel()
            if !controlDown { held = false }
            return false
        }
        if rightDown {
            if !held { eligible = clean }
            else if !clean { cancel() }
            held = true
            return false
        }
        let toggle = held && eligible && clean
        held = false
        eligible = false
        return toggle
    }
}
