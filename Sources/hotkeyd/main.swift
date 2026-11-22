import Foundation
import HotkeydCore

let arguments = Array(CommandLine.arguments.dropFirst())
let preDoubleDash = arguments.prefix(while: { $0 != "--" })
let jsonRequested = preDoubleDash.contains { arg in
    let lower = arg.lowercased()
    return lower == "--json" || lower == "--json=true" || lower == "--json=1"
}

do {
    try dispatch(arguments)
} catch let error as CLIError {
    if jsonRequested {
        emitErrorJSON(
            code: error.code,
            kind: error.resolvedKind,
            message: error.message,
            hint: error.hint
        )
    } else {
        let cleanMsg = StrictModes.sanitizeTerminalLines(error.message)
        FileHandle.standardError.write(Data(("hotkeyd: \(cleanMsg)\n").utf8))
        if let hint = error.hint, !hint.isEmpty {
            let cleanHint = StrictModes.sanitizeTerminalLines(hint)
            FileHandle.standardError.write(Data(("hint: \(cleanHint)\n").utf8))
        }
    }
    exit(error.code)
} catch {
    if jsonRequested {
        emitErrorJSON(code: 1, kind: "error", message: error.localizedDescription, hint: nil)
    } else {
        let cleanMsg = StrictModes.sanitizeTerminalLines(error.localizedDescription)
        FileHandle.standardError.write(Data(("hotkeyd: \(cleanMsg)\n").utf8))
    }
    exit(1)
}
