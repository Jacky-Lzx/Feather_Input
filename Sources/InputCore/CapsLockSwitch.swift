/// Caps Lock reports latch-state changes, not a normal key-down/key-up pair.
public struct CapsLockSwitch {
    private var locked = false
    public init() {}
    public mutating func reset(isLocked: Bool) { locked = isLocked }
    public mutating func flagsChanged(keyCode: UInt16, flags: UInt) -> Bool {
        let next = flags & (1 << 16) != 0
        let changed = next != locked
        locked = next
        let otherModifiers: UInt = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20) | (1 << 23)
        return (keyCode == 57 || keyCode == 0) && changed && flags & otherModifiers == 0
    }
}
