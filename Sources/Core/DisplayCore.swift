// Общий код для CLI (dspl) и приложения в статус-баре (DsplBar).
// Всё, что знает про мониторы, живёт здесь; интерфейсы поверх — тонкие.

import CoreGraphics
import Foundation
import IOKit

// MARK: - Приватный API

// Символ включает/выключает дисплей на уровне WindowServer.
// В свежих macOS живёт в SkyLight (SLS...), исторически — в CoreGraphics (CGS...).
public typealias ConfigureDisplayEnabled =
    @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

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

let missingSymbol = "не найден символ SLS/CGSConfigureDisplayEnabled — Apple убрала его в этой macOS"

// MARK: - Перечисление

func onlineDisplayIDs() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

func activeDisplayIDs() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

// Имена мониторов лежат в IORegistry, в DisplayAttributes/ProductAttributes.
// Ключ — пара (vendor, product), она же CGDisplayVendorNumber/CGDisplayModelNumber.
func ioDisplayNames() -> [UInt64: String] {
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
}

public let builtinDisplayName = "Built-in Display"

func liveName(_ id: CGDirectDisplayID, names: [UInt64: String]) -> String {
    if CGDisplayIsBuiltin(id) != 0 { return builtinDisplayName }
    let key = UInt64(CGDisplayVendorNumber(id)) << 32 | UInt64(CGDisplayModelNumber(id))
    return names[key] ?? "Display \(id)"
}

// MARK: - Снимок

// Выключенный дисплей выпадает не только из active, но и из online — система его
// больше не показывает. Без сохранённого списка `list` не покажет погашенный
// монитор, а `reset` не сможет его вернуть.

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

// MARK: - Публичная модель

public struct DisplayInfo {
    public let id: CGDirectDisplayID
    public let number: Int
    public let name: String
    public let width: Int
    public let height: Int
    public let isActive: Bool

    public var isBuiltin: Bool { name == builtinDisplayName }
    public var resolution: String { "\(width)x\(height)" }
}

// Дописываем к сохранённому, а не перетираем: сейчас-online — не весь мир,
// какой-то дисплей может быть выключен именно нами. Заодно раздаём порядковые
// номера — сырой CGDirectDisplayID бывает вида 724045334 и руками не набирается.
@discardableResult
public func listDisplays() -> [DisplayInfo] {
    var byID: [CGDirectDisplayID: DisplaySnapshot] = [:]
    if let data = try? Data(contentsOf: stateURL),
       let saved = try? JSONDecoder().decode([DisplaySnapshot].self, from: data) {
        for snapshot in saved { byID[snapshot.id] = snapshot }
    }

    let names = ioDisplayNames()
    for id in onlineDisplayIDs() {
        byID[id] = DisplaySnapshot(
            id: id,
            number: byID[id]?.number ?? 0,
            name: liveName(id, names: names),
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

    let snapshots = byID.values.sorted { $0.number < $1.number }
    try? JSONEncoder().encode(snapshots).write(to: stateURL)

    let active = Set(activeDisplayIDs())
    return snapshots.map {
        DisplayInfo(id: $0.id, number: $0.number, name: $0.name,
                    width: $0.width, height: $0.height, isActive: active.contains($0.id))
    }
}

/// Сколько дисплеев сейчас рисуют картинку. Дешёвая проверка без записи
/// state-файла — её дёргает сторож в приложении несколько раз в минуту.
public func activeDisplayCount() -> Int {
    activeDisplayIDs().count
}

// Роль, порядковый номер или имя монитора. Сырой id аргументом не принимаем:
// он нестабилен между переподключениями и в выводе есть только для справки.
public func resolveDisplay(_ argument: String) -> DisplayInfo? {
    let displays = listDisplays()
    let query = argument.lowercased()

    if query == "builtin" { return displays.first { $0.isBuiltin } }
    if query == "external" { return displays.first { !$0.isBuiltin } }
    if let number = Int(argument) { return displays.first { $0.number == number } }
    return displays.first { $0.name.lowercased() == query }
}

// MARK: - Применение

/// Возвращает nil при успехе, иначе текст ошибки.
public func setDisplay(_ id: CGDirectDisplayID, enabled: Bool) -> String? {
    guard let configure = configureDisplay else { return missingSymbol }

    if !enabled && activeDisplayIDs().filter({ $0 != id }).isEmpty {
        return "это последний активный дисплей"
    }
    listDisplays()   // запомнить состав, пока дисплей ещё виден системе

    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else {
        return "CGBeginDisplayConfiguration не удалась"
    }
    let error = configure(config, id, enabled)
    guard error == .success else {
        CGCancelDisplayConfiguration(config)
        return "CGError \(error.rawValue)"
    }
    // .forSession, а не .permanently: перезагрузка вернёт всё как было.
    CGCompleteDisplayConfiguration(config, .forSession)
    return nil
}

/// Возврат всего подряд: ошибки на несуществующих id глотаем, задача — вернуть
/// картинку любой ценой. Кроме сохранённых пробуем низкие id: встроенная панель
/// на Apple Silicon почти всегда 1, а в снимке её может не быть, если утилита
/// впервые запущена уже с погашенным экраном.
public func resetAllDisplays() -> String? {
    guard let configure = configureDisplay else { return missingSymbol }

    let candidates = Set(listDisplays().map { $0.id }).union(1...8)
    // Каждый id — своей транзакцией: неудачный вызов внутри общей конфигурации
    // валит её целиком, и валидные дисплеи тоже не включаются.
    for id in candidates.sorted() {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { continue }
        if configure(config, id, true) == .success {
            CGCompleteDisplayConfiguration(config, .forSession)
        } else {
            CGCancelDisplayConfiguration(config)
        }
    }
    return nil
}
