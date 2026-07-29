import Foundation

enum BundledAPIKey {
  private static let infoDictionaryKey = "BundledAnthropicAPIKeyPayload"

  static func load() -> String? {
    #if DEBUG || TESTFLIGHT
      guard
        let payload = Bundle.main.object(forInfoDictionaryKey: self.infoDictionaryKey) as? String
      else { return nil }
      return normalizedAPIKey(BundledAPIKeyPayload.decode(payload))
    #else
      return nil
    #endif
  }
}

enum BundledAPIKeyPayload {
  enum EncodingError: Error, Equatable {
    case emptyKey
    case maskLengthMismatch
  }

  static func encode(_ key: String, mask: [UInt8]) throws -> String {
    let keyBytes = Array(key.utf8)
    guard !keyBytes.isEmpty else { throw EncodingError.emptyKey }
    guard mask.count == keyBytes.count else { throw EncodingError.maskLengthMismatch }

    let ciphertext = zip(keyBytes, mask).map { $0.0 ^ $0.1 }
    return "v1.\(self.hex(mask)).\(self.hex(ciphertext))"
  }

  static func decode(_ payload: String) -> String? {
    let parts = payload.split(separator: ".", omittingEmptySubsequences: false)
    guard
      parts.count == 3,
      parts[0] == "v1",
      let mask = self.bytes(fromHex: parts[1]),
      let ciphertext = self.bytes(fromHex: parts[2]),
      !mask.isEmpty,
      mask.count == ciphertext.count
    else { return nil }

    let plaintext = zip(ciphertext, mask).map { $0.0 ^ $0.1 }
    return String(bytes: plaintext, encoding: .utf8)
  }

  private static func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  private static func bytes(fromHex hex: Substring) -> [UInt8]? {
    guard !hex.isEmpty, hex.count.isMultiple(of: 2) else { return nil }
    var result: [UInt8] = []
    result.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      result.append(byte)
      index = next
    }
    return result
  }
}
