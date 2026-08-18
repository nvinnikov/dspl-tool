// CLI поверх DisplayCore.

import Darwin
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text + " " : text.padding(toLength: width, withPad: " ", startingAt: 0)
}

func printList() {
    let displays = listDisplays()
    let nameWidth = max(4, displays.map { $0.name.count }.max() ?? 4)
    print(pad("#", 3) + pad("STATE", 7) + pad("NAME", nameWidth + 2) + pad("RESOLUTION", 12) + "ID")
    for display in displays {
        print(pad("\(display.number)", 3)
            + pad(display.isActive ? "on" : "OFF", 7)
            + pad(display.name, nameWidth + 2)
            + pad(display.resolution, 12)
            + "\(display.id)")
    }
}

// Ждём "y" на stdin. Молчание или что угодно другое — откат.
func confirmedWithinTimeout(_ seconds: Int32) -> Bool {
    var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    guard poll(&fds, 1, seconds * 1000) > 0 else { return false }
    guard let line = readLine(strippingNewline: true) else { return false }
    return ["y", "yes", "д", "да"].contains(line.trimmingCharacters(in: .whitespaces).lowercased())
}

// Спрашивать некого, если stdin не терминал — из Raycast или хоткея процесс
// иначе повис бы навсегда.
func disable(_ display: DisplayInfo, skipConfirm: Bool, timeout: Int32) -> Never {
    if let error = setDisplay(display.id, enabled: false) {
        fail("\(display.name): \(error)")
    }
    guard !skipConfirm, isatty(STDIN_FILENO) == 1 else { exit(0) }

    print("выключен: \(display.name). Оставить? [y/N], откат через \(timeout)с")
    if confirmedWithinTimeout(timeout) {
        print("оставлено")
        exit(0)
    }
    if let error = setDisplay(display.id, enabled: true) {
        fail("откат не удался: \(error)")
    }
    print("откат: \(display.name) включён обратно")
    exit(0)
}

var arguments = Array(CommandLine.arguments.dropFirst())
let skipConfirm = arguments.contains("-y") || arguments.contains("--yes")
arguments.removeAll { $0 == "-y" || $0 == "--yes" }

let timeout = Int32(ProcessInfo.processInfo.environment["DSPL_TIMEOUT"] ?? "") ?? 15
let command = arguments.first ?? "list"
let target = arguments.count > 1 ? arguments[1] : "builtin"

switch command {
case "list":
    printList()

case "off":
    guard let display = resolveDisplay(target) else { fail("дисплей не найден: \(target)") }
    disable(display, skipConfirm: skipConfirm, timeout: timeout)

case "on":
    guard let display = resolveDisplay(target) else { fail("дисплей не найден: \(target)") }
    if let error = setDisplay(display.id, enabled: true) { fail("\(display.name): \(error)") }

case "toggle":
    guard let display = resolveDisplay(target) else { fail("дисплей не найден: \(target)") }
    if display.isActive {
        disable(display, skipConfirm: skipConfirm, timeout: timeout)
    } else if let error = setDisplay(display.id, enabled: true) {
        fail("\(display.name): \(error)")
    }

case "reset":
    if let error = resetAllDisplays() { fail(error) }
    printList()

default:
    print("""
    dspl — включение и выключение мониторов

      dspl list                                 список мониторов
      dspl off    [builtin|external|<#>|<имя>]  выключить (спросит подтверждение)
      dspl on     [builtin|external|<#>|<имя>]  включить
      dspl toggle [builtin|external|<#>|<имя>]  переключить
      dspl reset                                включить всё обратно

    Флаги:
      -y, --yes        не спрашивать подтверждение
      DSPL_TIMEOUT=5   таймаут отката в секундах (по умолчанию 15)
    """)
    exit(1)
}
