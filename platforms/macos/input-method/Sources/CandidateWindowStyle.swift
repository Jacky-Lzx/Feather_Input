import AppKit

struct CandidateWindowMetrics {
  let candidateFont: NSFont
  let indexFont: NSFont
  let preeditFont: NSFont
  let expandedHeaderFont: NSFont
  let candidateHeight: CGFloat
  let indexWidth: CGFloat
  let preeditHeight: CGFloat
  let expandedHeaderHeight: CGFloat
  let fallbackColumnWidth: CGFloat
}

enum CandidateWindowStyle {
  static let minimumCompactWidth: CGFloat = 84
  static let maximumWidth: CGFloat = 540
  static let cornerRadius: CGFloat = 12
  static let borderWidth: CGFloat = 0.5
  static let contentInsets = NSEdgeInsets(top: 7, left: 7, bottom: 7, right: 7)
  static let candidateSpacing: CGFloat = 2
  static let candidateCornerRadius: CGFloat = 7
  static let candidateHorizontalPadding: CGFloat = 6
  static let candidateLabelSpacing: CGFloat = 4
  static let panelGap: CGFloat = 7
  static let screenInset: CGFloat = 6
  static let expandedColumnCount = 5
  static let expandedColumnSpacing: CGFloat = 4

  static func metrics(fontSize: CGFloat) -> CandidateWindowMetrics {
    let headerSize = max(10, fontSize * 0.68)
    return CandidateWindowMetrics(
      candidateFont: .systemFont(ofSize: fontSize, weight: .regular),
      indexFont: .monospacedDigitSystemFont(
        ofSize: max(10, fontSize * 0.74),
        weight: .semibold
      ),
      preeditFont: .systemFont(ofSize: max(11, fontSize * 0.82), weight: .medium),
      expandedHeaderFont: .systemFont(ofSize: headerSize, weight: .medium),
      candidateHeight: ceil(fontSize * 1.4) + 12,
      indexWidth: max(14, ceil(fontSize * 0.9)),
      preeditHeight: ceil(max(11, fontSize * 0.82)) + 7,
      expandedHeaderHeight: ceil(headerSize) + 8,
      fallbackColumnWidth: max(72, ceil(fontSize * 4.65))
    )
  }
}
