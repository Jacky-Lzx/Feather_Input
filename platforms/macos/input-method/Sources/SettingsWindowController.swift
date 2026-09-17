import AppKit

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  static let shared = SettingsWindowController(
    modeMemory: .shared,
    schemeMemory: .shared
  )

  private let modeMemory: InputModeMemory
  private let schemeMemory: InputSchemeMemory
  private var window: NSWindow?
  private weak var schemePopup: NSPopUpButton?
  private weak var policyPopup: NSPopUpButton?

  init(modeMemory: InputModeMemory, schemeMemory: InputSchemeMemory) {
    self.modeMemory = modeMemory
    self.schemeMemory = schemeMemory
  }

  func show() {
    let window = requireWindow()
    refreshControls()
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  func close() {
    window?.close()
  }

  func selectScheme(_ scheme: InputScheme) {
    schemeMemory.update(scheme)
    refreshControls()
  }

  func selectModePolicy(_ policy: InputModeMemoryPolicy) {
    modeMemory.updatePolicy(policy)
    refreshControls()
  }

  private func requireWindow() -> NSWindow {
    if let window { return window }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 430, height: 250),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "Feather Input 设置"
    window.isReleasedWhenClosed = false
    window.delegate = self

    let content = NSView()
    window.contentView = content

    let title = NSTextField(labelWithString: "输入设置")
    title.font = .systemFont(ofSize: 20, weight: .semibold)

    let schemeLabel = NSTextField(labelWithString: "中文输入方案")
    schemeLabel.font = .systemFont(ofSize: 13, weight: .medium)
    let schemePopup = NSPopUpButton()
    for scheme in InputScheme.allCases {
      schemePopup.addItem(withTitle: scheme.title)
      schemePopup.lastItem?.representedObject = scheme.rawValue
    }
    schemePopup.target = self
    schemePopup.action = #selector(schemeChanged(_:))
    self.schemePopup = schemePopup

    let policyLabel = NSTextField(labelWithString: "中英文模式记忆")
    policyLabel.font = .systemFont(ofSize: 13, weight: .medium)
    let policyPopup = NSPopUpButton()
    for policy in InputModeMemoryPolicy.allCases {
      policyPopup.addItem(withTitle: policy.title)
      policyPopup.lastItem?.representedObject = policy.rawValue
    }
    policyPopup.target = self
    policyPopup.action = #selector(policyChanged(_:))
    self.policyPopup = policyPopup

    let help = NSTextField(
      wrappingLabelWithString:
        "输入方案会在返回文本客户端时应用。中英文仍可通过右 Control 或 Control + Shift + Space 切换。"
    )
    help.font = .systemFont(ofSize: 12)
    help.textColor = .secondaryLabelColor

    let grid = NSGridView(views: [
      [schemeLabel, schemePopup],
      [policyLabel, policyPopup],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.column(at: 1).xPlacement = .fill
    grid.rowSpacing = 12
    grid.columnSpacing = 12

    let stack = NSStackView(views: [title, grid, help])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 18
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)

    grid.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    help.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
    ])

    self.window = window
    refreshControls()
    return window
  }

  private func refreshControls() {
    if let index = InputScheme.allCases.firstIndex(of: schemeMemory.load()) {
      schemePopup?.selectItem(at: index)
    }
    if let index = InputModeMemoryPolicy.allCases.firstIndex(of: modeMemory.policy) {
      policyPopup?.selectItem(at: index)
    }
  }

  @objc private func schemeChanged(_ sender: NSPopUpButton) {
    guard let rawValue = sender.selectedItem?.representedObject as? String,
      let scheme = InputScheme(rawValue: rawValue)
    else { return }
    selectScheme(scheme)
  }

  @objc private func policyChanged(_ sender: NSPopUpButton) {
    guard let rawValue = sender.selectedItem?.representedObject as? String,
      let policy = InputModeMemoryPolicy(rawValue: rawValue)
    else { return }
    selectModePolicy(policy)
  }
}
