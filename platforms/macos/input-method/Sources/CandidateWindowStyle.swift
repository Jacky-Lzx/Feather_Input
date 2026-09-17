import AppKit

enum CandidateWindowStyle {
  static let minimumWidth: CGFloat = 0
  static let maximumWidth: CGFloat = 540
  static let cornerRadius: CGFloat = 12
  static let borderWidth: CGFloat = 0.5
  static let contentInsets = NSEdgeInsets(top: 7, left: 7, bottom: 7, right: 7)
  static let candidateSpacing: CGFloat = 2
  static let candidateHeight: CGFloat = 34
  static let candidateCornerRadius: CGFloat = 7
  static let candidateHorizontalPadding: CGFloat = 6
  static let candidateLabelSpacing: CGFloat = 4
  static let indexWidth: CGFloat = 14
  static let panelGap: CGFloat = 7
  static let screenInset: CGFloat = 6
  static let fallbackColumnWidth: CGFloat = 72
  static let expandedColumnCount = 5
  static let expandedColumnSpacing: CGFloat = 4
  static let expandedHeaderHeight: CGFloat = 18

  static let candidateFont = NSFont.systemFont(ofSize: 15.5, weight: .regular)
  static let indexFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
  static let expandedHeaderFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
}
