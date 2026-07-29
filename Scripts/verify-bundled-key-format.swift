import Darwin
import Foundation

enum VerificationError: Error, CustomStringConvertible {
  case invalidArguments
  case rejectedPayload

  var description: String {
    switch self {
    case .invalidArguments: "Expected 'decode <payload>'."
    case .rejectedPayload: "The runtime decoder rejected the payload."
    }
  }
}

@main
enum BundledKeyFormatVerifier {
  static func main() {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      switch arguments.first {
      case "decode" where arguments.count == 2:
        guard let key = BundledAPIKeyPayload.decode(arguments[1]) else {
          throw VerificationError.rejectedPayload
        }
        print(key)

      default:
        throw VerificationError.invalidArguments
      }
    } catch {
      FileHandle.standardError.write(Data("error: \(error)\n".utf8))
      exit(1)
    }
  }
}
