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
    var number: Int          // порядковый номер для человека, 0 — ещё не назначен
    let name: String
    let width: Int
    let height: Int

    init(id: CGDirectDisplayID, number: Int, name: String, width: Int, height: Int) {
        self.id = id; self.number = number; self.name = name
        self.width = width; self.height = height
    }

    // number появился позже — старый state-файл без него должен читаться.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(CGDirectDisplayID.self, forKey: .id)
        number = try container.decodeIfPresent(Int.self, forKey: .number) ?? 0
        name = try container.decode(String.self, forKey: .name)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
    }
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
// какой-то дисплей может быть выключен именно нами. Заодно раздаём порядковые
// номера — сырой CGDirectDisplayID бывает вида 724045334 и руками не набирается.
func knownDisplays() -> [DisplaySnapshot] {
    var byID: [CGDirectDisplayID: DisplaySnapshot] = [:]
    for snapshot in loadSnapshots() { byID[snapshot.id] = snapshot }
    for id in onlineDisplays() {
        byID[id] = DisplaySnapshot(
            id: id,
            number: byID[id]?.number ?? 0,
            name: liveName(id),
            width: CGDisplayPixelsWide(id),
            height: CGDisplayPixelsHigh(id)
        )
    }

    var used = Set(byID.values.map(\.number).filter { $0 > 0 })
    for id in byID.keys.sorted() where byID[id]!.number == 0 {
        var next = 1
        while used.contains(next) { next += 1 }
        byID[id]!.number = next
        used.insert(next)
    }

    let displays = byID.values.sorted { $0.number < $1.number }
    try? JSONEncoder().encode(displays).write(to: stateURL)
    return displays
}

// MARK: - Вывод

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text + " " : text.padding(toLength: width, withPad: " ", startingAt: 0)
}

func printList() {
    let active = Set(activeDisplays())
    let displays = knownDisplays()
    let nameWidth = max(4, displays.map { $0.name.count }.max() ?? 4)
    print("\(pad("#", 3))\(pad("STATE", 7))\(pad("NAME", nameWidth + 2))\(pad("RESOLUTION", 12))ID")
    for display in displays {
        let state = active.contains(display.id) ? "on" : "OFF"
        print(pad("\(display.number)", 3)
            + pad(state, 7)
            + pad(display.name, nameWidth + 2)
            + pad("\(display.width)x\(display.height)", 12)
            + "\(display.id)")
    }
}

// Роль, порядковый номер или имя монитора. Сырой id аргументом не принимаем:
// он нестабилен между переподключениями и в выводе есть только для справки.
func resolve(_ argument: String) -> CGDirectDisplayID? {
    let displays = knownDisplays()
    let query = argument.lowercased()

    if query == "builtin" {
        return displays.first { $0.name == "Built-in Display" }?.id
    }
    if query == "external" {
        return displays.first { $0.name != "Built-in Display" }?.id
    }
    if let number = Int(argument) {
        return displays.first { $0.number == number }?.id
    }
    return displays.first { $0.name.lowercased() == query }?.id
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
    _ = knownDisplays()
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
    printList()

case "off":
    guard let id = resolve(target) else { fail("дисплей не найден: \(target)") }
    disable(id, name: liveName(id), skipConfirm: skipConfirm, timeout: timeout)

case "on":
    guard let id = resolve(target) else { fail("дисплей не найден: \(target)") }
    apply([(id, true)])
    _ = knownDisplays()

case "toggle":
    guard let id = resolve(target) else { fail("дисплей не найден: \(target)") }
    if activeDisplays().contains(id) {
        disable(id, name: liveName(id), skipConfirm: skipConfirm, timeout: timeout)
    } else {
        apply([(id, true)])
        _ = knownDisplays()
    }

case "reset":
    resetAll()
    printList()

default:
    print("""
    dspl — включение и выключение мониторов

      dspl list                             список мониторов
      dspl off    [builtin|external|<#>|<имя>]   выключить (спросит подтверждение)
      dspl on     [builtin|external|<#>|<имя>]   включить
      dspl toggle [builtin|external|<#>|<имя>]   переключить
      dspl reset                            включить всё обратно

    Флаги:
      -y, --yes        не спрашивать подтверждение
      DSPL_TIMEOUT=10  таймаут отката в секундах (по умолчанию 5)
    """)
    exit(1)
}
