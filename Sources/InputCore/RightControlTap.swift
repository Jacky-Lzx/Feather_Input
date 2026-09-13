/// Tracks a right-Control press/release without consuming Control shortcuts.
public struct RightControlTap {
    // NX_DEVICERCTLKEYMASK / NX_DEVICELCTLKEYMASK from IOLLEvent.h.
    public static let rightControl: UInt = 0x2000
    private static let disallowed: UInt = 0x1 | (1 << 17) | (1 << 19) | (1 << 20) | (1 << 23)
    private var leftHeld = false
    private var held = false
    private var eligible = false
    private var lastRelease: Double?
    // Reject a second press beginning within 40 ms of a release. IMK traces
    // contain duplicated complete taps ~7 ms apart, not just repeated downs.
    private static let debounceInterval = 0.040
    public init() {}
    public mutating func cancel() { eligible = false }
    public mutating func reset() { leftHeld = false; held = false; eligible = false }
    public mutating func flagsChanged(keyCode: UInt16, flags: UInt, timestamp: Double? = nil) -> Bool {
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
            if !held {
                let repeated: Bool
                if let timestamp, let lastRelease {
                    repeated = timestamp - lastRelease < Self.debounceInterval
                } else { repeated = false }
                eligible = clean && !repeated
            }
            else if !clean { cancel() }
            held = true
            return false
        }
        let toggle = held && eligible && clean
        // Include rejected taps in the quiet period, so a burst cannot retrigger.
        if held, let timestamp { lastRelease = max(lastRelease ?? timestamp, timestamp) }
        held = false
        eligible = false
        return toggle
    }
}
