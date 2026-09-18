import AppKit

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  static let shared = SettingsWindowController(
    modeMemory: .shared,
    schemeMemory: .shared,
    persistentModeIndicatorSettings: .shared,
    focusIndicatorSettings: .shared,
    candidatePageSettings: .shared,
    candidateLayoutSettings: .shared,
    candidateFontSettings: .shared,
    englishCandidateSettings: .shared,
    generationSettings: .shared,
    continuationSettings: .shared,
    rerankingSettings: .shared,
    generationBackendStatusCheck: { FeatherMLXBackendStatusProbe.check() }
  )

  private let modeMemory: InputModeMemory
  private let schemeMemory: InputSchemeMemory
  private let persistentModeIndicatorSettings: PersistentModeIndicatorSettings
  private let focusIndicatorSettings: FocusIndicatorSettings
  private let candidatePageSettings: CandidatePageSettings
  private let candidateLayoutSettings: CandidateLayoutSettings
  private let candidateFontSettings: CandidateFontSettings
  private let englishCandidateSettings: EnglishCandidateSettings
  private let generationSettings: GenerationSettings
  private let continuationSettings: ContinuationSettings
  private let rerankingSettings: RerankingSettings
  private let generationBackendStatusCheck: @Sendable () -> MLXBackendStatus
  private var window: NSWindow?
  private weak var schemePopup: NSPopUpButton?
  private weak var policyPopup: NSPopUpButton?
  private weak var persistentModeIndicatorButton: NSButton?
  private weak var focusUntilInputButton: NSButton?
  private weak var focusDurationValue: NSTextField?
  private weak var focusDurationStepper: NSStepper?
  private weak var candidateCountValue: NSTextField?
  private weak var candidateCountStepper: NSStepper?
  private weak var candidateLayoutPopup: NSPopUpButton?
  private weak var candidateFontValue: NSTextField?
  private weak var candidateFontSlider: NSSlider?
  private weak var englishCandidateMinimumValue: NSTextField?
  private weak var englishCandidateMinimumStepper: NSStepper?
  private weak var generationEnabledButton: NSButton?
  private weak var continuationEnabledButton: NSButton?
  private weak var rerankingEnabledButton: NSButton?
  private weak var rerankingCandidateCountValue: NSTextField?
  private weak var rerankingCandidateCountStepper: NSStepper?
  private weak var rerankingWeightValue: NSTextField?
  private weak var rerankingWeightSlider: NSSlider?
  private weak var rerankingDebounceValue: NSTextField?
  private weak var rerankingDebounceStepper: NSStepper?
  private weak var rerankingDeadlineValue: NSTextField?
  private weak var rerankingDeadlineStepper: NSStepper?
  private weak var generationBackendStatusLabel: NSTextField?
  private weak var generationBackendStatusButton: NSButton?
  private var generationBackendStatusVersion = UUID()

  init(
    modeMemory: InputModeMemory,
    schemeMemory: InputSchemeMemory,
    persistentModeIndicatorSettings: PersistentModeIndicatorSettings,
    focusIndicatorSettings: FocusIndicatorSettings,
    candidatePageSettings: CandidatePageSettings,
    candidateLayoutSettings: CandidateLayoutSettings,
    candidateFontSettings: CandidateFontSettings,
    englishCandidateSettings: EnglishCandidateSettings,
    generationSettings: GenerationSettings,
    continuationSettings: ContinuationSettings,
    rerankingSettings: RerankingSettings,
    generationBackendStatusCheck: @escaping @Sendable () -> MLXBackendStatus = {
      FeatherMLXBackendStatusProbe.check()
    }
  ) {
    self.modeMemory = modeMemory
    self.schemeMemory = schemeMemory
    self.persistentModeIndicatorSettings = persistentModeIndicatorSettings
    self.focusIndicatorSettings = focusIndicatorSettings
    self.candidatePageSettings = candidatePageSettings
    self.candidateLayoutSettings = candidateLayoutSettings
    self.candidateFontSettings = candidateFontSettings
    self.englishCandidateSettings = englishCandidateSettings
    self.generationSettings = generationSettings
    self.continuationSettings = continuationSettings
    self.rerankingSettings = rerankingSettings
    self.generationBackendStatusCheck = generationBackendStatusCheck
  }

  func show() {
    let window = requireWindow()
    refreshControls()
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    refreshGenerationBackendStatus()
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

  func selectPersistentModeIndicatorEnabled(_ isEnabled: Bool) {
    persistentModeIndicatorSettings.updateEnabled(isEnabled)
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

  func selectCandidateFontSize(_ size: CGFloat) {
    candidateFontSettings.updateSize(size)
    refreshControls()
  }

  func selectEnglishCandidateMinimum(_ minimum: Int) {
    englishCandidateSettings.updateMinimumInputLength(minimum)
    refreshControls()
  }

  func selectGenerationEnabled(_ isEnabled: Bool) {
    generationSettings.updateEnabled(isEnabled)
    refreshControls()
  }

  func selectContinuationEnabled(_ isEnabled: Bool) {
    continuationSettings.updateEnabled(isEnabled)
    refreshControls()
  }

  func selectRerankingEnabled(_ enabled: Bool) {
    rerankingSettings.updateEnabled(enabled)
    refreshControls()
  }

  func selectRerankingWeight(_ weight: Double) {
    rerankingSettings.updateWeight(weight)
    refreshControls()
  }

  func selectRerankingCandidateCount(_ count: Int) {
    rerankingSettings.updateCandidateCount(count)
    refreshControls()
  }

  func selectRerankingDebounceMilliseconds(_ milliseconds: UInt64) {
    rerankingSettings.updateDebounceMilliseconds(milliseconds)
    refreshControls()
  }

  func selectRerankingAdoptionDeadlineMilliseconds(_ milliseconds: UInt64) {
    rerankingSettings.updateAdoptionDeadlineMilliseconds(milliseconds)
    refreshControls()
  }

  func refreshGenerationBackendStatus() {
    let version = UUID()
    generationBackendStatusVersion = version
    generationBackendStatusLabel?.stringValue = MLXBackendStatus.checking.displayText
    generationBackendStatusButton?.isEnabled = false
    let check = generationBackendStatusCheck
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let status = check()
      DispatchQueue.main.async {
        guard let self, self.generationBackendStatusVersion == version else { return }
        self.generationBackendStatusLabel?.stringValue = status.displayText
        self.generationBackendStatusButton?.isEnabled = true
      }
    }
  }

  var displayedGenerationBackendStatus: String? {
    generationBackendStatusLabel?.stringValue
  }

  private func requireWindow() -> NSWindow {
    if let window { return window }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 810),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "Feather Input 设置"
    window.isReleasedWhenClosed = false
    window.delegate = self

    let content = NSView()
    window.contentView = content
    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(scrollView)
    let document = NSView()
    document.translatesAutoresizingMaskIntoConstraints = false
    scrollView.documentView = document

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

    let persistentModeIndicatorButton = NSButton(
      checkboxWithTitle: "屏幕左下角常驻显示中／英",
      target: self,
      action: #selector(persistentModeIndicatorChanged(_:))
    )
    self.persistentModeIndicatorButton = persistentModeIndicatorButton

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

    let candidateFontValue = NSTextField(labelWithString: "")
    candidateFontValue.alignment = .right
    candidateFontValue.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    self.candidateFontValue = candidateFontValue
    let candidateFontSlider = NSSlider(
      value: Double(candidateFontSettings.size),
      minValue: Double(CandidateFontSettings.minimumSize),
      maxValue: Double(CandidateFontSettings.maximumSize),
      target: self,
      action: #selector(candidateFontChanged(_:))
    )
    candidateFontSlider.numberOfTickMarks =
      Int(CandidateFontSettings.maximumSize - CandidateFontSettings.minimumSize) + 1
    candidateFontSlider.allowsTickMarkValuesOnly = true
    candidateFontSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
    self.candidateFontSlider = candidateFontSlider
    let candidateFontControls = NSStackView(views: [candidateFontSlider, candidateFontValue])
    candidateFontControls.orientation = .horizontal
    candidateFontControls.alignment = .centerY
    candidateFontControls.spacing = 8

    let candidateFontHelp = NSTextField(
      wrappingLabelWithString: "下一次显示候选窗时生效，无需重启。"
    )
    candidateFontHelp.font = .systemFont(ofSize: 12)
    candidateFontHelp.textColor = .secondaryLabelColor

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

    let generationEnabledButton = NSButton(
      checkboxWithTitle: "根据上下文和拼音生成新词（实验）",
      target: self,
      action: #selector(generationEnabledChanged(_:))
    )
    self.generationEnabledButton = generationEnabledButton

    let continuationEnabledButton = NSButton(
      checkboxWithTitle: "上屏后显示 AI 续写候选（实验）",
      target: self,
      action: #selector(continuationEnabledChanged(_:))
    )
    self.continuationEnabledButton = continuationEnabledButton

    let rerankingEnabledButton = NSButton(
      checkboxWithTitle: "用 AI 重排 Rime 候选（实验）",
      target: self,
      action: #selector(rerankingEnabledChanged(_:))
    )
    self.rerankingEnabledButton = rerankingEnabledButton

    let rerankingCandidateCountValue = NSTextField(labelWithString: "")
    rerankingCandidateCountValue.alignment = .right
    rerankingCandidateCountValue.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    self.rerankingCandidateCountValue = rerankingCandidateCountValue
    let rerankingCandidateCountStepper = NSStepper()
    rerankingCandidateCountStepper.minValue = Double(RerankingSettings.minimumCandidateCount)
    rerankingCandidateCountStepper.maxValue = Double(RerankingSettings.maximumCandidateCount)
    rerankingCandidateCountStepper.increment = 1
    rerankingCandidateCountStepper.target = self
    rerankingCandidateCountStepper.action = #selector(rerankingCandidateCountChanged(_:))
    self.rerankingCandidateCountStepper = rerankingCandidateCountStepper
    let rerankingCandidateCountControls = NSStackView(views: [
      rerankingCandidateCountValue, rerankingCandidateCountStepper,
    ])
    rerankingCandidateCountControls.orientation = .horizontal
    rerankingCandidateCountControls.alignment = .centerY
    rerankingCandidateCountControls.spacing = 8

    let rerankingWeightValue = NSTextField(labelWithString: "")
    rerankingWeightValue.alignment = .right
    rerankingWeightValue.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    self.rerankingWeightValue = rerankingWeightValue
    let rerankingWeightSlider = NSSlider(
      value: RerankingSettings.defaultWeight * 100,
      minValue: 0,
      maxValue: 100,
      target: self,
      action: #selector(rerankingWeightChanged(_:))
    )
    rerankingWeightSlider.numberOfTickMarks = 21
    rerankingWeightSlider.allowsTickMarkValuesOnly = true
    self.rerankingWeightSlider = rerankingWeightSlider
    let rerankingWeightControls = NSStackView(views: [
      rerankingWeightValue, rerankingWeightSlider,
    ])
    rerankingWeightControls.orientation = .horizontal
    rerankingWeightControls.alignment = .centerY
    rerankingWeightControls.spacing = 8

    let rerankingDebounceValue = NSTextField(labelWithString: "")
    rerankingDebounceValue.alignment = .right
    rerankingDebounceValue.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    self.rerankingDebounceValue = rerankingDebounceValue
    let rerankingDebounceStepper = NSStepper()
    rerankingDebounceStepper.minValue = 0
    rerankingDebounceStepper.maxValue = 2_000
    rerankingDebounceStepper.increment = 10
    rerankingDebounceStepper.target = self
    rerankingDebounceStepper.action = #selector(rerankingDebounceChanged(_:))
    self.rerankingDebounceStepper = rerankingDebounceStepper
    let rerankingDebounceControls = NSStackView(views: [
      rerankingDebounceValue, rerankingDebounceStepper,
    ])
    rerankingDebounceControls.orientation = .horizontal
    rerankingDebounceControls.alignment = .centerY
    rerankingDebounceControls.spacing = 8

    let rerankingDeadlineValue = NSTextField(labelWithString: "")
    rerankingDeadlineValue.alignment = .right
    rerankingDeadlineValue.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    self.rerankingDeadlineValue = rerankingDeadlineValue
    let rerankingDeadlineStepper = NSStepper()
    rerankingDeadlineStepper.minValue = 50
    rerankingDeadlineStepper.maxValue = 2_000
    rerankingDeadlineStepper.increment = 50
    rerankingDeadlineStepper.target = self
    rerankingDeadlineStepper.action = #selector(rerankingDeadlineChanged(_:))
    self.rerankingDeadlineStepper = rerankingDeadlineStepper
    let rerankingDeadlineControls = NSStackView(views: [
      rerankingDeadlineValue, rerankingDeadlineStepper,
    ])
    rerankingDeadlineControls.orientation = .horizontal
    rerankingDeadlineControls.alignment = .centerY
    rerankingDeadlineControls.spacing = 8

    let rerankingHelp = NSTextField(
      wrappingLabelWithString: "排序数量可与每页候选不同；数量越多耗时越长。继续输入或开始选词后不会采用迟到结果。"
    )
    rerankingHelp.font = .systemFont(ofSize: 12)
    rerankingHelp.textColor = .secondaryLabelColor

    let generationHelp = NSTextField(
      wrappingLabelWithString:
        "完整输入拼音后，侧边最多显示 3 个本地 MLX 建议；按 Option + 数字、Option + 空格或点击上屏。后端不可用时不影响普通候选。"
    )
    generationHelp.font = .systemFont(ofSize: 12)
    generationHelp.textColor = .secondaryLabelColor

    let continuationHelp = NSTextField(
      wrappingLabelWithString:
        "文字上屏后停顿 400 ms，侧边显示最多 3 个本地 MLX 续写候选；可点击或按 Option + 数字/空格插入，其他新输入会立即取消。"
    )
    continuationHelp.font = .systemFont(ofSize: 12)
    continuationHelp.textColor = .secondaryLabelColor

    let generationBackendStatusLabel = NSTextField(
      labelWithString: MLXBackendStatus.checking.displayText
    )
    generationBackendStatusLabel.textColor = .secondaryLabelColor
    self.generationBackendStatusLabel = generationBackendStatusLabel
    let generationBackendStatusButton = NSButton(
      title: "刷新",
      target: self,
      action: #selector(refreshGenerationBackendStatusClicked(_:))
    )
    generationBackendStatusButton.bezelStyle = .rounded
    self.generationBackendStatusButton = generationBackendStatusButton
    let generationBackendStatusControls = NSStackView(views: [
      generationBackendStatusLabel, generationBackendStatusButton,
    ])
    generationBackendStatusControls.orientation = .horizontal
    generationBackendStatusControls.alignment = .centerY
    generationBackendStatusControls.spacing = 8

    let emptyPolicyHelp = NSTextField(labelWithString: "")
    let emptyPersistentModeIndicator = NSTextField(labelWithString: "")
    let emptyFocusToggle = NSTextField(labelWithString: "")
    let emptyFocusHelp = NSTextField(labelWithString: "")
    let emptyDurationHelp = NSTextField(labelWithString: "")
    let emptyCandidateCountHelp = NSTextField(labelWithString: "")
    let emptyCandidateFontHelp = NSTextField(labelWithString: "")
    let emptyEnglishCandidateMinimumHelp = NSTextField(labelWithString: "")
    let emptyGenerationToggle = NSTextField(labelWithString: "")
    let emptyGenerationHelp = NSTextField(labelWithString: "")
    let emptyGenerationBackendStatus = NSTextField(labelWithString: "")
    let emptyContinuationToggle = NSTextField(labelWithString: "")
    let emptyContinuationHelp = NSTextField(labelWithString: "")
    let emptyRerankingToggle = NSTextField(labelWithString: "")
    let emptyRerankingHelp = NSTextField(labelWithString: "")

    let grid = NSGridView(views: [
      [schemeLabel, schemePopup],
      [policyLabel, policyPopup],
      [emptyPolicyHelp, policyHelp],
      [emptyPersistentModeIndicator, persistentModeIndicatorButton],
      [emptyFocusToggle, focusUntilInputButton],
      [emptyFocusHelp, focusHelp],
      [NSTextField(labelWithString: "焦点提示显示"), focusDurationControls],
      [emptyDurationHelp, focusDurationHelp],
      [candidateLayoutLabel, candidateLayoutPopup],
      [NSTextField(labelWithString: "候选字号"), candidateFontControls],
      [emptyCandidateFontHelp, candidateFontHelp],
      [NSTextField(labelWithString: "拼音每页候选"), candidateCountControls],
      [emptyCandidateCountHelp, candidateCountHelp],
      [NSTextField(labelWithString: "英文候选最少输入"), englishCandidateMinimumControls],
      [emptyEnglishCandidateMinimumHelp, englishCandidateMinimumHelp],
      [emptyRerankingToggle, rerankingEnabledButton],
      [NSTextField(labelWithString: "AI 排序候选数"), rerankingCandidateCountControls],
      [NSTextField(labelWithString: "AI 融合权重"), rerankingWeightControls],
      [NSTextField(labelWithString: "AI 请求前停顿"), rerankingDebounceControls],
      [NSTextField(labelWithString: "AI 响应采用时限"), rerankingDeadlineControls],
      [emptyRerankingHelp, rerankingHelp],
      [emptyGenerationToggle, generationEnabledButton],
      [emptyGenerationHelp, generationHelp],
      [emptyContinuationToggle, continuationEnabledButton],
      [emptyContinuationHelp, continuationHelp],
      [emptyGenerationBackendStatus, generationBackendStatusControls],
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
    document.addSubview(stack)

    grid.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    policyHelp.widthAnchor.constraint(equalToConstant: 300).isActive = true
    focusHelp.widthAnchor.constraint(equalToConstant: 300).isActive = true
    focusDurationHelp.widthAnchor.constraint(equalToConstant: 300).isActive = true
    candidateCountHelp.widthAnchor.constraint(equalToConstant: 300).isActive = true
    candidateFontHelp.widthAnchor.constraint(equalToConstant: 300).isActive = true
    englishCandidateMinimumHelp.widthAnchor.constraint(equalToConstant: 300).isActive = true
    generationHelp.widthAnchor.constraint(equalToConstant: 300).isActive = true
    continuationHelp.widthAnchor.constraint(equalToConstant: 300).isActive = true
    rerankingHelp.widthAnchor.constraint(equalToConstant: 300).isActive = true
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: content.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
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
    persistentModeIndicatorButton?.state =
      persistentModeIndicatorSettings.isEnabled ? .on : .off
    let waitsUntilInput = focusIndicatorSettings.waitsUntilInput
    focusUntilInputButton?.state = waitsUntilInput ? .on : .off
    focusDurationValue?.stringValue = String(format: "%.1f 秒", focusIndicatorSettings.duration)
    focusDurationStepper?.doubleValue = focusIndicatorSettings.duration
    focusDurationStepper?.isEnabled = !waitsUntilInput
    candidateCountValue?.stringValue = "\(candidatePageSettings.count)"
    candidateCountStepper?.integerValue = candidatePageSettings.count
    candidateFontValue?.stringValue = "\(Int(candidateFontSettings.size))"
    candidateFontSlider?.doubleValue = Double(candidateFontSettings.size)
    englishCandidateMinimumValue?.stringValue =
      "\(englishCandidateSettings.minimumInputLength) 个字符"
    englishCandidateMinimumStepper?.integerValue = englishCandidateSettings.minimumInputLength
    generationEnabledButton?.state = generationSettings.isEnabled ? .on : .off
    continuationEnabledButton?.state = continuationSettings.isEnabled ? .on : .off
    let rerankingEnabled = rerankingSettings.isEnabled
    rerankingEnabledButton?.state = rerankingEnabled ? .on : .off
    rerankingCandidateCountValue?.stringValue = "\(rerankingSettings.candidateCount)"
    rerankingCandidateCountStepper?.integerValue = rerankingSettings.candidateCount
    rerankingCandidateCountStepper?.isEnabled = rerankingEnabled
    rerankingWeightValue?.stringValue = "\(Int((rerankingSettings.weight * 100).rounded()))%"
    rerankingWeightSlider?.doubleValue = rerankingSettings.weight * 100
    rerankingWeightSlider?.isEnabled = rerankingEnabled
    rerankingDebounceValue?.stringValue = "\(rerankingSettings.debounceMilliseconds) ms"
    rerankingDebounceStepper?.integerValue = Int(rerankingSettings.debounceMilliseconds)
    rerankingDebounceStepper?.isEnabled = rerankingEnabled
    rerankingDeadlineValue?.stringValue =
      "\(rerankingSettings.adoptionDeadlineMilliseconds) ms"
    rerankingDeadlineStepper?.integerValue = Int(
      rerankingSettings.adoptionDeadlineMilliseconds)
    rerankingDeadlineStepper?.isEnabled = rerankingEnabled
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

  @objc private func persistentModeIndicatorChanged(_ sender: NSButton) {
    selectPersistentModeIndicatorEnabled(sender.state == .on)
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

  @objc private func candidateFontChanged(_ sender: NSSlider) {
    selectCandidateFontSize(CGFloat(sender.doubleValue))
  }

  @objc private func englishCandidateMinimumChanged(_ sender: NSStepper) {
    selectEnglishCandidateMinimum(sender.integerValue)
  }

  @objc private func generationEnabledChanged(_ sender: NSButton) {
    selectGenerationEnabled(sender.state == .on)
  }

  @objc private func continuationEnabledChanged(_ sender: NSButton) {
    selectContinuationEnabled(sender.state == .on)
  }

  @objc private func rerankingEnabledChanged(_ sender: NSButton) {
    selectRerankingEnabled(sender.state == .on)
  }

  @objc private func rerankingWeightChanged(_ sender: NSSlider) {
    selectRerankingWeight(sender.doubleValue / 100)
  }

  @objc private func rerankingCandidateCountChanged(_ sender: NSStepper) {
    selectRerankingCandidateCount(sender.integerValue)
  }

  @objc private func rerankingDebounceChanged(_ sender: NSStepper) {
    selectRerankingDebounceMilliseconds(UInt64(sender.integerValue))
  }

  @objc private func rerankingDeadlineChanged(_ sender: NSStepper) {
    selectRerankingAdoptionDeadlineMilliseconds(UInt64(sender.integerValue))
  }

  @objc private func refreshGenerationBackendStatusClicked(_ sender: NSButton) {
    refreshGenerationBackendStatus()
  }
}
