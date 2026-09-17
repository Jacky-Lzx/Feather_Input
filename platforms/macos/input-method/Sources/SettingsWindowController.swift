import AppKit

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  static let shared = SettingsWindowController(
    modeMemory: .shared,
    schemeMemory: .shared,
    focusIndicatorSettings: .shared,
    candidatePageSettings: .shared,
    candidateLayoutSettings: .shared,
    englishCandidateSettings: .shared
  )

  private let modeMemory: InputModeMemory
  private let schemeMemory: InputSchemeMemory
  private let focusIndicatorSettings: FocusIndicatorSettings
  private let candidatePageSettings: CandidatePageSettings
  private let candidateLayoutSettings: CandidateLayoutSettings
  private let englishCandidateSettings: EnglishCandidateSettings
  private var window: NSWindow?
  private weak var schemePopup: NSPopUpButton?
  private weak var policyPopup: NSPopUpButton?
  private weak var focusUntilInputButton: NSButton?
  private weak var focusDurationValue: NSTextField?
  private weak var focusDurationStepper: NSStepper?
  private weak var candidateCountValue: NSTextField?
  private weak var candidateCountStepper: NSStepper?
  private weak var candidateLayoutPopup: NSPopUpButton?
  private weak var englishCandidateMinimumValue: NSTextField?
  private weak var englishCandidateMinimumStepper: NSStepper?

  init(
    modeMemory: InputModeMemory,
    schemeMemory: InputSchemeMemory,
    focusIndicatorSettings: FocusIndicatorSettings,
    candidatePageSettings: CandidatePageSettings,
    candidateLayoutSettings: CandidateLayoutSettings,
    englishCandidateSettings: EnglishCandidateSettings
  ) {
    self.modeMemory = modeMemory
    self.schemeMemory = schemeMemory
    self.focusIndicatorSettings = focusIndicatorSettings
    self.candidatePageSettings = candidatePageSettings
    self.candidateLayoutSettings = candidateLayoutSettings
    self.englishCandidateSettings = englishCandidateSettings
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

  func selectFocusIndicatorWaitsUntilInput(_ waitsUntilInput: Bool) {
    focusIndicatorSettings.updateWaitsUntilInput(waitsUntilInput)
    refreshControls()
  }

  func selectFocusIndicatorDuration(_ duration: TimeInterval) {
    focusIndicatorSettings.updateDuration(duration)
    refreshControls()
  }

  func selectCandidateCount(_ count: Int) {
    candidatePageSettings.updateCount(count)
    refreshControls()
  }

  func selectCandidateLayout(_ layout: CandidateLayout) {
    candidateLayoutSettings.update(layout)
    refreshControls()
  }

  func selectEnglishCandidateMinimum(_ minimum: Int) {
    englishCandidateSettings.updateMinimumInputLength(minimum)
    refreshControls()
  }

  private func requireWindow() -> NSWindow {
    if let window { return window }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 590),
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

    let policyHelp = NSTextField(
      wrappingLabelWithString:
        "全局记忆会让所有应用共享最后一次状态；按应用记忆会分别保存。恢复模式仅在切换到另一个应用时重置。"
    )
    policyHelp.font = .systemFont(ofSize: 12)
    policyHelp.textColor = .secondaryLabelColor

    let focusUntilInputButton = NSButton(
      checkboxWithTitle: "焦点状态提示持续到开始输入",
      target: self,
      action: #selector(focusUntilInputChanged(_:))
    )
    self.focusUntilInputButton = focusUntilInputButton

    let focusHelp = NSTextField(
      wrappingLabelWithString:
        "开启后，光标旁的中英文提示会保持到开始按键或失焦；关闭后按下方时间自动消失。下次获得焦点生效。"
    )
    focusHelp.font = .systemFont(ofSize: 12)
    focusHelp.textColor = .secondaryLabelColor

    let focusDurationValue = NSTextField(labelWithString: "")
    focusDurationValue.alignment = .right
    focusDurationValue.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    self.focusDurationValue = focusDurationValue
    let focusDurationStepper = NSStepper()
    focusDurationStepper.minValue = FocusIndicatorSettings.minimumDuration
    focusDurationStepper.maxValue = FocusIndicatorSettings.maximumDuration
    focusDurationStepper.increment = 0.1
    focusDurationStepper.target = self
    focusDurationStepper.action = #selector(focusDurationChanged(_:))
    self.focusDurationStepper = focusDurationStepper
    let focusDurationControls = NSStackView(views: [focusDurationValue, focusDurationStepper])
    focusDurationControls.orientation = .horizontal
    focusDurationControls.alignment = .centerY
    focusDurationControls.spacing = 8

    let focusDurationHelp = NSTextField(
      wrappingLabelWithString: "仅在关闭“持续到开始输入”时生效，范围 0.1–5.0 秒。"
    )
    focusDurationHelp.font = .systemFont(ofSize: 12)
    focusDurationHelp.textColor = .secondaryLabelColor

    let candidateCountValue = NSTextField(labelWithString: "")
    candidateCountValue.alignment = .right
    candidateCountValue.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    self.candidateCountValue = candidateCountValue
    let candidateCountStepper = NSStepper()
    candidateCountStepper.minValue = Double(CandidatePageSettings.minimumCount)
    candidateCountStepper.maxValue = Double(CandidatePageSettings.maximumCount)
    candidateCountStepper.increment = 1
    candidateCountStepper.target = self
    candidateCountStepper.action = #selector(candidateCountChanged(_:))
    self.candidateCountStepper = candidateCountStepper
    let candidateCountControls = NSStackView(views: [candidateCountValue, candidateCountStepper])
    candidateCountControls.orientation = .horizontal
    candidateCountControls.alignment = .centerY
    candidateCountControls.spacing = 8

    let candidateCountHelp = NSTextField(
      wrappingLabelWithString: "完成当前拼音后生效，无需重启。"
    )
    candidateCountHelp.font = .systemFont(ofSize: 12)
    candidateCountHelp.textColor = .secondaryLabelColor

    let candidateLayoutLabel = NSTextField(labelWithString: "候选排列")
    candidateLayoutLabel.font = .systemFont(ofSize: 13, weight: .medium)
    let candidateLayoutPopup = NSPopUpButton()
    for layout in CandidateLayout.allCases {
      candidateLayoutPopup.addItem(withTitle: layout.title)
      candidateLayoutPopup.lastItem?.representedObject = layout.rawValue
    }
    candidateLayoutPopup.target = self
    candidateLayoutPopup.action = #selector(candidateLayoutChanged(_:))
    self.candidateLayoutPopup = candidateLayoutPopup

    let englishCandidateMinimumValue = NSTextField(labelWithString: "")
    englishCandidateMinimumValue.alignment = .right
    englishCandidateMinimumValue.font = .monospacedDigitSystemFont(
      ofSize: 13,
      weight: .regular
    )
    self.englishCandidateMinimumValue = englishCandidateMinimumValue
    let englishCandidateMinimumStepper = NSStepper()
    englishCandidateMinimumStepper.minValue = Double(EnglishCandidateSettings.minimumValue)
    englishCandidateMinimumStepper.maxValue = Double(EnglishCandidateSettings.maximumValue)
    englishCandidateMinimumStepper.increment = 1
    englishCandidateMinimumStepper.target = self
    englishCandidateMinimumStepper.action = #selector(englishCandidateMinimumChanged(_:))
    self.englishCandidateMinimumStepper = englishCandidateMinimumStepper
    let englishCandidateMinimumControls = NSStackView(views: [
      englishCandidateMinimumValue, englishCandidateMinimumStepper,
    ])
    englishCandidateMinimumControls.orientation = .horizontal
    englishCandidateMinimumControls.alignment = .centerY
    englishCandidateMinimumControls.spacing = 8

    let englishCandidateMinimumHelp = NSTextField(
      wrappingLabelWithString: "输入达到该长度后才会出现英文候选；完成当前组合后生效。"
    )
    englishCandidateMinimumHelp.font = .systemFont(ofSize: 12)
    englishCandidateMinimumHelp.textColor = .secondaryLabelColor

    let emptyPolicyHelp = NSTextField(labelWithString: "")
    let emptyFocusToggle = NSTextField(labelWithString: "")
    let emptyFocusHelp = NSTextField(labelWithString: "")
    let emptyDurationHelp = NSTextField(labelWithString: "")
    let emptyCandidateCountHelp = NSTextField(labelWithString: "")
    let emptyEnglishCandidateMinimumHelp = NSTextField(labelWithString: "")

    let grid = NSGridView(views: [
      [schemeLabel, schemePopup],
      [policyLabel, policyPopup],
      [emptyPolicyHelp, policyHelp],
      [emptyFocusToggle, focusUntilInputButton],
      [emptyFocusHelp, focusHelp],
      [NSTextField(labelWithString: "焦点提示显示"), focusDurationControls],
      [emptyDurationHelp, focusDurationHelp],
      [candidateLayoutLabel, candidateLayoutPopup],
      [NSTextField(labelWithString: "拼音每页候选"), candidateCountControls],
      [emptyCandidateCountHelp, candidateCountHelp],
      [NSTextField(labelWithString: "英文候选最少输入"), englishCandidateMinimumControls],
      [emptyEnglishCandidateMinimumHelp, englishCandidateMinimumHelp],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.column(at: 1).xPlacement = .fill
    grid.rowSpacing = 12
    grid.columnSpacing = 12

    let stack = NSStackView(views: [title, grid])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 18
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)

    grid.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    policyHelp.widthAnchor.constraint(equalToConstant: 300).isActive = true
    focusHelp.widthAnchor.constraint(equalToConstant: 300).isActive = true
    focusDurationHelp.widthAnchor.constraint(equalToConstant: 300).isActive = true
    candidateCountHelp.widthAnchor.constraint(equalToConstant: 300).isActive = true
    englishCandidateMinimumHelp.widthAnchor.constraint(equalToConstant: 300).isActive = true
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
    let waitsUntilInput = focusIndicatorSettings.waitsUntilInput
    focusUntilInputButton?.state = waitsUntilInput ? .on : .off
    focusDurationValue?.stringValue = String(format: "%.1f 秒", focusIndicatorSettings.duration)
    focusDurationStepper?.doubleValue = focusIndicatorSettings.duration
    focusDurationStepper?.isEnabled = !waitsUntilInput
    candidateCountValue?.stringValue = "\(candidatePageSettings.count)"
    candidateCountStepper?.integerValue = candidatePageSettings.count
    englishCandidateMinimumValue?.stringValue =
      "\(englishCandidateSettings.minimumInputLength) 个字符"
    englishCandidateMinimumStepper?.integerValue = englishCandidateSettings.minimumInputLength
    if let index = CandidateLayout.allCases.firstIndex(of: candidateLayoutSettings.layout) {
      candidateLayoutPopup?.selectItem(at: index)
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

  @objc private func focusUntilInputChanged(_ sender: NSButton) {
    selectFocusIndicatorWaitsUntilInput(sender.state == .on)
  }

  @objc private func focusDurationChanged(_ sender: NSStepper) {
    selectFocusIndicatorDuration(sender.doubleValue)
  }

  @objc private func candidateCountChanged(_ sender: NSStepper) {
    selectCandidateCount(sender.integerValue)
  }

  @objc private func candidateLayoutChanged(_ sender: NSPopUpButton) {
    guard let rawValue = sender.selectedItem?.representedObject as? String,
      let layout = CandidateLayout(rawValue: rawValue)
    else { return }
    selectCandidateLayout(layout)
  }

  @objc private func englishCandidateMinimumChanged(_ sender: NSStepper) {
    selectEnglishCandidateMinimum(sender.integerValue)
  }
}
