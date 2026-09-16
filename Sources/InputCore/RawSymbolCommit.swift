import Foundation

public enum RawSymbolCommit {
    public static func shouldCommit(rawInput: String, symbol: String) -> Bool {
        guard !rawInput.isEmpty,
              rawInput.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
              symbol.unicodeScalars.count == 1,
              let scalar = symbol.unicodeScalars.first,
              scalar.isASCII,
              (33...126).contains(scalar.value),
              !CharacterSet.alphanumerics.contains(scalar) else { return false }
        return true
    }
}
