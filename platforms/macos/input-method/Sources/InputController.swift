import AppKit
import Carbon
import InputMethodKit

private enum NormalizedInput {
  case key(FeatherKey)
  case text(String)
}

@objc(FeatherRustInputController)
@MainActor
final class InputController: IMKInputController {
  var secureInputEnabled: () -> Bool = { IsSecureEventInputEnabled() }
  private var injectedCandidatePresenter: CandidatePresenting?
  private lazy var ownedCandidatePresenter = OwnedCandidatePresenter()
  var candidatePresenter: CandidatePresenting {
    get { injectedCandidatePresenter ?? ownedCandidatePresenter }
    set { injectedCandidatePresenter = newValue }
  }
  private var session: FeatherSession?
  private var currentResponse: FeatherResponseValue?
  private weak var activeClient: AnyObject?
  private var active = false

  override func activateServer(_ sender: Any!) {
    activeClient = sender as AnyObject?
    if injectedCandidatePresenter == nil {
      ownedCandidatePresenter.activate()
    }
    candidatePresenter.actionHandler = { [weak self] action in
      self?.handleCandidateWindowAction(action)
    }
    do {
      let session = try requireSession()
      currentResponse = try session.activate()
      active = true
    } catch {
      active = false
      report(error, operation: "activate")
    }
  }

  override func deactivateServer(_ sender: Any!) {
    guard let session else {
      active = false
      currentResponse = nil
      activeClient = nil
      candidatePresenter.actionHandler = nil
      candidatePresenter.hide()
      if injectedCandidatePresenter == nil {
        ownedCandidatePresenter.deactivate()
      }
      return
    }
    do {
      let response = try session.deactivate()
      if let client = sender as? IMKTextInput {
        apply(response, to: client)
      }
    } catch {
      report(error, operation: "deactivate")
    }
    active = false
    currentResponse = nil
    activeClient = nil
    candidatePresenter.actionHandler = nil
    candidatePresenter.hide()
    if injectedCandidatePresenter == nil {
      ownedCandidatePresenter.deactivate()
    }
  }

  override func recognizedEvents(_ sender: Any!) -> Int {
    Int(NSEvent.EventTypeMask.keyDown.rawValue)
  }

  override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    guard let event, event.type == .keyDown, let client = sender as? IMKTextInput else {
      return false
    }
    guard !secureInputEnabled() else {
      cancelEngineComposition()
      return false
    }

    if event.keyCode == 53, hasComposition {
      return dispatch(.escape, to: client)
    }
    guard textInputAvailable(client) else {
      cancelEngineComposition()
      return false
    }
    let shortcutModifiers = event.modifierFlags.intersection([.command, .control, .option])
    guard shortcutModifiers.isEmpty, let input = normalizedInput(for: event) else {
      return false
    }
    switch input {
    case .key(let key):
      return dispatch(key, to: client)
    case .text(let text):
      return dispatch(text: text, to: client)
    }
  }

  override func commitComposition(_ sender: Any!) {
    guard hasComposition, let client = sender as? IMKTextInput else { return }
    _ = dispatch(.enter, to: client)
  }

  override func composedString(_ sender: Any!) -> Any! {
    currentResponse?.preedit ?? ""
  }

  override func candidates(_ sender: Any!) -> [Any]! {
    currentResponse?.candidates.map(\.text) ?? []
  }

  private var hasComposition: Bool {
    currentResponse?.preedit.isEmpty == false
  }

  private func requireSession() throws -> FeatherSession {
    if let session { return session }
    let session = try FeatherSession(
      sharedData: FeatherInputEnvironment.sharedData(),
      userData: FeatherInputEnvironment.userData(),
      schema: FeatherInputEnvironment.schema
    )
    self.session = session
    return session
  }

  private func ensureActive() throws -> FeatherSession {
    let session = try requireSession()
    if !active {
      currentResponse = try session.activate()
      active = true
    }
    return session
  }

  private func dispatch(_ key: FeatherKey, to client: IMKTextInput) -> Bool {
    let wasComposing = hasComposition
    do {
      let response = try ensureActive().send(key)
      guard response.handled else {
        return wasComposing && isCandidateNavigation(key)
      }
      apply(response, to: client)
      return true
    } catch {
      report(error, operation: "key \(key)")
      return false
    }
  }

  private func isCandidateNavigation(_ key: FeatherKey) -> Bool {
    switch key {
    case .left, .right, .up, .down, .pageUp, .pageDown:
      return true
    default:
      return false
    }
  }

  private func dispatch(text: String, to client: IMKTextInput) -> Bool {
    do {
      let response = try ensureActive().send(text: text)
      guard response.handled else { return false }
      apply(response, to: client)
      return true
    } catch {
      report(error, operation: "text")
      return false
    }
  }

  private func apply(_ response: FeatherResponseValue, to client: IMKTextInput) {
    currentResponse = response
    if let commit = response.commit, !commit.isEmpty {
      client.insertText(commit, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    let selection = NSRange(
      location: TextCoordinates.utf16Offset(in: response.preedit, utf8Offset: response.cursorUTF8),
      length: 0
    )
    client.setMarkedText(
      response.preedit,
      selectionRange: selection,
      replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    if response.preedit.isEmpty || response.candidates.isEmpty {
      candidatePresenter.hide()
    } else {
      candidatePresenter.update(
        candidates: response.candidates,
        highlighted: response.highlighted,
        anchor: candidateAnchor(for: client)
      )
    }
  }

  private func handleCandidateWindowAction(_ action: CandidateWindowAction) {
    guard let client = activeClient as? IMKTextInput else {
      candidatePresenter.hide()
      return
    }
    switch action {
    case .select(let candidate):
      do {
        let response = try ensureActive().select(candidate)
        guard response.handled else { return }
        apply(response, to: client)
      } catch {
        report(error, operation: "select candidate")
      }
    case .pageUp:
      _ = dispatch(.pageUp, to: client)
    case .pageDown:
      _ = dispatch(.pageDown, to: client)
    }
  }

  private func candidateAnchor(for client: IMKTextInput) -> NSRect {
    let range =
      client.markedRange().location == NSNotFound
      ? client.selectedRange()
      : client.markedRange()
    var actualRange = NSRange(location: NSNotFound, length: 0)
    return client.firstRect(forCharacterRange: range, actualRange: &actualRange)
  }

  private func normalizedInput(for event: NSEvent) -> NormalizedInput? {
    switch event.keyCode {
    case 51: return .key(.backspace)
    case 117: return .key(.delete)
    case 49: return .key(.space)
    case 36, 76: return .key(.enter)
    case 53: return .key(.escape)
    case 123: return .key(.pageUp)
    case 124: return .key(.pageDown)
    case 125: return .key(.down)
    case 126: return .key(.up)
    case 116: return .key(.pageUp)
    case 121: return .key(.pageDown)
    default:
      guard let text = event.charactersIgnoringModifiers, isPrintableASCII(text) else {
        return nil
      }
      return .text(text)
    }
  }

  private func isPrintableASCII(_ text: String) -> Bool {
    !text.isEmpty && text.utf8.allSatisfy { (0x20...0x7e).contains($0) }
  }

  private func textInputAvailable(_ client: IMKTextInput) -> Bool {
    client.selectedRange().location != NSNotFound
  }

  private func cancelEngineComposition() {
    guard hasComposition, let session else { return }
    currentResponse = try? session.send(.escape)
    candidatePresenter.hide()
  }

  private func report(_ error: Error, operation: String) {
    NSLog("Feather Input Rust Dev \(operation) 失败：\(error.localizedDescription)")
  }
}
