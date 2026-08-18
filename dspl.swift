// dspl — включение и выключение мониторов на macOS из терминала.
// build: swiftc -O dspl.swift -o dspl

import CoreGraphics
import Foundation
import IOKit

// MARK: - Приватный API

// Символ включает/выключает дисплей на уровне WindowServer.
// В свежих macOS живёт в SkyLight (SLS...), исторически — в CoreGraphics (CGS...).
typealias ConfigureDisplayEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

let configureDisplay: ConfigureDisplayEnabled? = {
    let libs = [
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
    ]
    for lib in libs {
        guard let handle = dlopen(lib, RTLD_LAZY) else { continue }
        for symbol in ["SLSConfigureDisplayEnabled", "CGSConfigureDisplayEnabled"] {
            if let address = dlsym(handle, symbol) {
                return unsafeBitCast(address, to: ConfigureDisplayEnabled.self)
            }
        }
    }
    return nil
}()

// MARK: - Перечисление дисплеев

func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

func activeDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

// Имена мониторов лежат в IORegistry, в DisplayAttributes/ProductAttributes.
// Ключ — пара (vendor, product), она же CGDisplayVendorNumber/CGDisplayModelNumber.
let ioDisplayNames: [UInt64: String] = {
    var names: [UInt64: String] = [:]
    var iterator: io_iterator_t = 0
    let root = IORegistryGetRootEntry(kIOMainPortDefault)
    guard IORegistryEntryCreateIterator(
        root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator
    ) == KERN_SUCCESS else { return names }

    var entry = IOIteratorNext(iterator)
    while entry != 0 {
        if let attributes = IORegistryEntryCreateCFProperty(
                entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0
           )?.takeRetainedValue() as? [String: Any],
           let product = attributes["ProductAttributes"] as? [String: Any],
           let name = product["ProductName"] as? String {
            let vendor = (product["LegacyManufacturerID"] as? UInt64) ?? 0
            let model = (product["ProductID"] as? UInt64) ?? 0
            names[vendor << 32 | model] = name
        }
        IOObjectRelease(entry)
        entry = IOIteratorNext(iterator)
    }
    IOObjectRelease(iterator)
    return names
}()

func liveName(_ id: CGDirectDisplayID) -> String {
    if CGDisplayIsBuiltin(id) != 0 { return "Built-in Display" }
    let key = UInt64(CGDisplayVendorNumber(id)) << 32 | UInt64(CGDisplayModelNumber(id))
    return ioDisplayNames[key] ?? "Display \(id)"
}

// MARK: - Снимок дисплеев

// Выключенный дисплей выпадает не только из active, но и из online — система его
// больше не показывает. Поэтому храним последний известный список: без него
// `list` не покажет погашенный монитор, а `reset` не сможет его вернуть.

struct DisplaySnapshot: Codable {
    let id: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int
}

let stateURL: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("dspl.json")
}()

func loadSnapshots() -> [DisplaySnapshot] {
    guard let data = try? Data(contentsOf: stateURL) else { return [] }
    return (try? JSONDecoder().decode([DisplaySnapshot].self, from: data)) ?? []
}

// Дописываем к сохранённым, а не перетираем: сейчас-online — не весь мир,
// какой-то дисплей может быть выключен именно нами.
func rememberOnlineDisplays() {
    var byID: [CGDirectDisplayID: DisplaySnapshot] = [:]
    for snapshot in loadSnapshots() { byID[snapshot.id] = snapshot }
    for id in onlineDisplays() {
        byID[id] = DisplaySnapshot(
            id: id,
            name: liveName(id),
            width: CGDisplayPixelsWide(id),
            height: CGDisplayPixelsHigh(id)
        )
    }
    let sorted = byID.values.sorted { $0.id < $1.id }
    try? JSONEncoder().encode(sorted).write(to: stateURL)
}

func knownDisplays() -> [DisplaySnapshot] {
    var byID: [CGDirectDisplayID: DisplaySnapshot] = [:]
    for snapshot in loadSnapshots() { byID[snapshot.id] = snapshot }
    for id in onlineDisplays() {
        byID[id] = DisplaySnapshot(
            id: id,
            name: liveName(id),
            width: CGDisplayPixelsWide(id),
            height: CGDisplayPixelsHigh(id)
        )
    }
    return byID.values.sorted { $0.id < $1.id }
}

// MARK: - Вывод

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func printList() {
    let active = Set(activeDisplays())
    for display in knownDisplays() {
        let state = active.contains(display.id) ? "on " : "OFF"
        let name = display.name.padding(toLength: 22, withPad: " ", startingAt: 0)
        print("\(display.id)\t\(state)\t\(name)\t\(display.width)x\(display.height)")
    }
}

func resolve(_ argument: String) -> CGDirectDisplayID? {
    let displays = knownDisplays()
    switch argument {
    case "builtin":
        return displays.first { $0.name == "Built-in Display" }?.id
            ?? onlineDisplays().first { CGDisplayIsBuiltin($0) != 0 }
    case "external":
        return displays.first { $0.name != "Built-in Display" }?.id
            ?? onlineDisplays().first { CGDisplayIsBuiltin($0) == 0 }
    default:
        return CGDirectDisplayID(argument)
    }
}

// MARK: - Применение

func apply(_ changes: [(CGDirectDisplayID, Bool)]) {
    guard let configure = configureDisplay else {
        fail("не найден символ SLS/CGSConfigureDisplayEnabled — Apple убрала его в этой macOS")
    }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else {
        fail("CGBeginDisplayConfiguration не удалась")
    }
    for (id, enabled) in changes {
        let error = configure(config, id, enabled)
        guard error == .success else {
            CGCancelDisplayConfiguration(config)
            fail("не удалось применить к дисплею \(id): CGError \(error.rawValue)")
        }
    }
    // .forSession, а не .permanently: перезагрузка вернёт всё как было.
    CGCompleteDisplayConfiguration(config, .forSession)
}

// Возврат всего подряд: ошибки на несуществующих id глотаем, задача — вернуть
// картинку любой ценой. Кроме сохранённых пробуем низкие id: встроенная панель
// на Apple Silicon почти всегда 1, а в снимке её может не быть, если утилита
// впервые запущена уже с погашенным экраном.
func resetAll() {
    guard let configure = configureDisplay else {
        fail("не найден символ SLS/CGSConfigureDisplayEnabled — Apple убрала его в этой macOS")
    }
    // Каждый id — своей транзакцией: неудачный вызов внутри общей конфигурации
    // валит её целиком, и валидные дисплеи тоже не включаются.
    let candidates = Set(knownDisplays().map { $0.id }).union(1...8)
    for id in candidates.sorted() {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { continue }
        if configure(config, id, true) == .success {
            CGCompleteDisplayConfiguration(config, .forSession)
        } else {
            CGCancelDisplayConfiguration(config)
        }
    }
}

// MARK: - Подтверждение с откатом

// Ждём "y" на stdin. Молчание или что угодно другое — откат.
func confirmedWithinTimeout(_ seconds: Int32) -> Bool {
    var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    guard poll(&fds, 1, seconds * 1000) > 0 else { return false }
    guard let line = readLine(strippingNewline: true) else { return false }
    return ["y", "yes", "д", "да"].contains(line.trimmingCharacters(in: .whitespaces).lowercased())
}

// Спрашивать некого, если stdin не терминал — из Raycast или хоткея процесс
// иначе повис бы навсегда.
func shouldConfirm(skipRequested: Bool) -> Bool {
    !skipRequested && isatty(STDIN_FILENO) == 1
}

func disable(_ id: CGDirectDisplayID, name: String, skipConfirm: Bool, timeout: Int32) -> Never {
    if activeDisplays().filter({ $0 != id }).isEmpty {
        fail("отказ: \(name) — последний активный дисплей")
    }
    rememberOnlineDisplays()
    apply([(id, false)])

    guard shouldConfirm(skipRequested: skipConfirm) else { exit(0) }

    print("выключен: \(name). Оставить? [y/N], откат через \(timeout)с")
    if confirmedWithinTimeout(timeout) {
        print("оставлено")
        exit(0)
    }
    apply([(id, true)])
    print("откат: \(name) включён обратно")
    exit(0)
}

// MARK: - Разбор аргументов

var arguments = Array(CommandLine.arguments.dropFirst())
let skipConfirm = arguments.contains("-y") || arguments.contains("--yes")
arguments.removeAll { $0 == "-y" || $0 == "--yes" }

let timeout = Int32(ProcessInfo.processInfo.environment["DSPL_TIMEOUT"] ?? "") ?? 5
let command = arguments.first ?? "list"
let target = arguments.count > 1 ? arguments[1] : "builtin"

switch command {
case "list":
    rememberOnlineDisplays()
    printList()

case "off":
    guard let id = resolve(target) else { fail("дисплей не найден: \(target)") }
    disable(id, name: liveName(id), skipConfirm: skipConfirm, timeout: timeout)

case "on":
    guard let id = resolve(target) else { fail("дисплей не найден: \(target)") }
    apply([(id, true)])
    rememberOnlineDisplays()

case "toggle":
    guard let id = resolve(target) else { fail("дисплей не найден: \(target)") }
    if activeDisplays().contains(id) {
        disable(id, name: liveName(id), skipConfirm: skipConfirm, timeout: timeout)
    } else {
        apply([(id, true)])
        rememberOnlineDisplays()
    }

case "reset":
    resetAll()
    rememberOnlineDisplays()
    printList()

default:
    print("""
    dspl — включение и выключение мониторов

      dspl list                        список всех известных мониторов
      dspl off    [builtin|external|<id>]   выключить (спросит подтверждение)
      dspl on     [builtin|external|<id>]   включить
      dspl toggle [builtin|external|<id>]   переключить
      dspl reset                       включить всё обратно

    Флаги:
      -y, --yes        не спрашивать подтверждение
      DSPL_TIMEOUT=10  таймаут отката в секундах (по умолчанию 5)
    """)
    exit(1)
}
