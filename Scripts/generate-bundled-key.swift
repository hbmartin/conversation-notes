#!/usr/bin/env swift

import Darwin
import Foundation
import Security

enum GeneratorError: Error, CustomStringConvertible {
  case noTerminal
  case emptyKey
  case invalidKey
  case invalidArguments
  case randomFailure(OSStatus)

  var description: String {
    switch self {
    case .noTerminal: "Could not securely read from the terminal."
    case .emptyKey: "The API key cannot be empty."
    case .invalidKey: "The API key must begin with sk-ant- and contain only printable ASCII."
    case .invalidArguments: "The generator does not accept command-line arguments."
    case .randomFailure(let status): "Could not generate random bytes (OSStatus \(status))."
    }
  }
}

func writeError(_ message: String) {
  FileHandle.standardError.write(Data(message.utf8))
}

func securelyReadKey() throws -> String {
  var original = termios()
  guard tcgetattr(STDIN_FILENO, &original) == 0 else { throw GeneratorError.noTerminal }
  var hidden = original
  hidden.c_lflag &= ~tcflag_t(ECHO)

  writeError("Anthropic API key: ")
  guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden) == 0 else {
    throw GeneratorError.noTerminal
  }
  defer {
    _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
    writeError("\n")
  }

  guard let value = readLine() else { throw GeneratorError.emptyKey }
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { throw GeneratorError.emptyKey }
  guard
    trimmed.hasPrefix("sk-ant-"),
    trimmed.utf8.allSatisfy({ (33...126).contains($0) })
  else { throw GeneratorError.invalidKey }
  return trimmed
}

func hex(_ bytes: [UInt8]) -> String {
  bytes.map { String(format: "%02x", $0) }.joined()
}

func makeBundledKeyPayload(key: String, mask: [UInt8]) throws -> String {
  let keyBytes = Array(key.utf8)
  guard !keyBytes.isEmpty else { throw GeneratorError.emptyKey }
  guard
    key.hasPrefix("sk-ant-"),
    keyBytes.allSatisfy({ (33...126).contains($0) }),
    keyBytes.count == mask.count
  else { throw GeneratorError.invalidKey }
  let ciphertext = zip(keyBytes, mask).map { $0.0 ^ $0.1 }
  return "v1.\(hex(mask)).\(hex(ciphertext))"
}

func repositoryRoot(scriptPath: String = #filePath) -> URL {
  let scriptURL: URL
  if scriptPath.hasPrefix("/") {
    scriptURL = URL(fileURLWithPath: scriptPath)
  } else {
    scriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(scriptPath)
  }
  return scriptURL.standardizedFileURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  if arguments == ["--emit-test-vector"] {
    // Fixed fake data for Scripts/test-bundled-key-format.sh. Never put a real key in argv.
    print(
      try makeBundledKeyPayload(
        key: "sk-ant-test",
        mask: [UInt8](repeating: 0, count: 11)
      )
    )
    exit(0)
  }
  guard arguments.isEmpty else { throw GeneratorError.invalidArguments }

  let key = try securelyReadKey()
  let keyBytes = Array(key.utf8)
  var mask = [UInt8](repeating: 0, count: keyBytes.count)
  let status = mask.withUnsafeMutableBytes { buffer in
    SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, buffer.baseAddress!)
  }
  guard status == errSecSuccess else { throw GeneratorError.randomFailure(status) }

  let payload = try makeBundledKeyPayload(key: key, mask: mask)
  let outputURL = repositoryRoot().appendingPathComponent("Config/BundledKey.private.xcconfig")
  let contents = "BUNDLED_ANTHROPIC_API_KEY_PAYLOAD = \(payload)\n"
  try contents.write(to: outputURL, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o600],
    ofItemAtPath: outputURL.path
  )
  print("Wrote obfuscated bundled-key payload to \(outputURL.path)")
} catch {
  writeError("error: \(error)\n")
  exit(1)
}
