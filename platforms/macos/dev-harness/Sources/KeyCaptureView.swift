import AppKit

@MainActor
final class KeyCaptureView: NSView {
  var eventHandler: ((NSEvent) -> Bool)?

  override var acceptsFirstResponder: Bool { true }

  override func becomeFirstResponder() -> Bool {
    needsDisplay = true
    return true
  }

  override func resignFirstResponder() -> Bool {
    needsDisplay = true
    return true
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
  }

  override func keyDown(with event: NSEvent) {
    if eventHandler?(event) != true {
      NSSound.beep()
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    let focused = window?.firstResponder === self
    let bounds = bounds.insetBy(dx: 0.5, dy: 0.5)
    let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
    NSColor.controlBackgroundColor.setFill()
    path.fill()
    (focused ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
    path.lineWidth = focused ? 2 : 1
    path.stroke()

    let message =
      focused
      ? "正在捕获按键 · Control-Space 切换直输模式"
      : "点击这里开始输入"
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 15, weight: .medium),
      .foregroundColor: focused ? NSColor.labelColor : NSColor.secondaryLabelColor,
    ]
    let size = message.size(withAttributes: attributes)
    message.draw(
      at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
      withAttributes: attributes
    )
  }
}
