// Управление яркостью мониторов.
//
// Внешние — через DDC/CI поверх I2C: публичного API нет, идём приватными
// символами IOAVService из IOKit. Встроенный — через DisplayServices, там DDC
// не при чём.
//
// Текущую яркость по DDC узнать удаётся не всегда: многие мониторы на запрос
// отвечают пустым кадром. Поэтому выставленное значение мы запоминаем сами.

import CoreGraphics
import Foundation
import IOKit

// MARK: - Приватные символы

typealias AVServiceCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
typealias AVServiceWriteI2C =
    @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
typealias SetDisplayBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
typealias GetDisplayBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

private let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
private let displayServices = dlopen(
    "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

private let avServiceCreate: AVServiceCreate? = dlsym(ioKit, "IOAVServiceCreateWithService")
    .map { unsafeBitCast($0, to: AVServiceCreate.self) }
private let avServiceWrite: AVServiceWriteI2C? = dlsym(ioKit, "IOAVServiceWriteI2C")
    .map { unsafeBitCast($0, to: AVServiceWriteI2C.self) }
private let setNativeBrightness: SetDisplayBrightness? = dlsym(displayServices, "DisplayServicesSetBrightness")
    .map { unsafeBitCast($0, to: SetDisplayBrightness.self) }
private let getNativeBrightness: GetDisplayBrightness? = dlsym(displayServices, "DisplayServicesGetBrightness")
    .map { unsafeBitCast($0, to: GetDisplayBrightness.self) }

// MARK: - Привязка монитора к каналу I2C

// Путь AV-сервиса и путь фреймбуфера сходятся на общем узле вида dispext0:
//   .../dispext0@C0000000/IOMobileFramebufferShim        — здесь EDID монитора
//   .../dispext0:dcpav-service-epic:0/DCPAVServiceProxy  — здесь канал I2C
// По этому токену связь однозначна, даже когда внешних мониторов несколько.

private func registryPath(_ entry: io_registry_entry_t) -> String {
    var buffer = [CChar](repeating: 0, count: 1024)
    IORegistryEntryGetPath(entry, kIOServicePlane, &buffer)
    return String(cString: buffer)
}

private func displayToken(in path: String) -> String? {
    for component in path.split(separator: "/") {
        let head = component.split(separator: ":").first.map(String.init) ?? String(component)
        let name = head.split(separator: "@").first.map(String.init) ?? head
        guard name.hasPrefix("disp"), name.dropFirst(4).contains(where: \.isNumber) else { continue }
        return name
    }
    return nil
}

private func avServicesByToken() -> [String: CFTypeRef] {
    guard let create = avServiceCreate else { return [:] }
    var services: [String: CFTypeRef] = [:]
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return [:] }
    defer { IOObjectRelease(iterator) }

    var entry = IOIteratorNext(iterator)
    while entry != 0 {
        let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString,
            kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        if location == "External",
           let token = displayToken(in: registryPath(entry)),
           let service = create(kCFAllocatorDefault, entry) {
            services[token] = service.takeRetainedValue()
        }
        IOObjectRelease(entry)
        entry = IOIteratorNext(iterator)
    }
    return services
}

private func tokensByDisplayKey() -> [UInt64: String] {
    var tokens: [UInt64: String] = [:]
    var iterator: io_iterator_t = 0
    let root = IORegistryGetRootEntry(kIOMainPortDefault)
    guard IORegistryEntryCreateIterator(root, kIOServicePlane,
        IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [:] }
    defer { IOObjectRelease(iterator) }

    var entry = IOIteratorNext(iterator)
    while entry != 0 {
        if let attributes = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString,
                kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
           let product = attributes["ProductAttributes"] as? [String: Any],
           let token = displayToken(in: registryPath(entry)) {
            let vendor = (product["LegacyManufacturerID"] as? UInt64) ?? 0
            let model = (product["ProductID"] as? UInt64) ?? 0
            tokens[vendor << 32 | model] = token
        }
        IOObjectRelease(entry)
        entry = IOIteratorNext(iterator)
    }
    return tokens
}

// Поиск канала обходит весь IORegistry, а ползунок дёргает запись десятки раз
// в секунду — без кеша это заметно тормозит. Сбрасывается при смене состава
// мониторов, см. invalidateBrightnessCache().
private var serviceCache: [CGDirectDisplayID: CFTypeRef] = [:]
private let cacheLock = NSLock()

public func invalidateBrightnessCache() {
    cacheLock.lock()
    serviceCache.removeAll()
    cacheLock.unlock()
}

private func avService(for id: CGDirectDisplayID) -> CFTypeRef? {
    cacheLock.lock()
    if let cached = serviceCache[id] { cacheLock.unlock(); return cached }
    cacheLock.unlock()

    let key = UInt64(CGDisplayVendorNumber(id)) << 32 | UInt64(CGDisplayModelNumber(id))
    guard let token = tokensByDisplayKey()[key],
          let service = avServicesByToken()[token] else { return nil }

    cacheLock.lock()
    serviceCache[id] = service
    cacheLock.unlock()
    return service
}

// MARK: - DDC

private let vcpBrightness: UInt8 = 0x10

private func writeDDC(_ service: CFTypeRef, command: UInt8, value: UInt16) -> Bool {
    guard let write = avServiceWrite else { return false }
    var packet: [UInt8] = [0x84, 0x03, command, UInt8(value >> 8), UInt8(value & 0xFF)]
    // Контрольная сумма считается по всему кадру, включая адреса получателя
    // и отправителя — их IOAVService передаёт отдельными аргументами.
    packet.append(packet.reduce(0x6E ^ 0x51 as UInt8) { $0 ^ $1 })
    return write(service, 0x37, 0x51, &packet, UInt32(packet.count)) == KERN_SUCCESS
}

// MARK: - Публичный интерфейс

public func supportsBrightness(_ id: CGDirectDisplayID) -> Bool {
    if CGDisplayIsBuiltin(id) != 0 { return setNativeBrightness != nil }
    return avService(for: id) != nil
}

/// Возвращает nil при успехе, иначе текст ошибки.
///
/// `persist` стоит выключать на промежуточных значениях: пока тянут ползунок,
/// писать state-файл на каждый шаг незачем.
public func setBrightness(_ id: CGDirectDisplayID, percent: Int, persist: Bool = true) -> String? {
    let clamped = max(0, min(100, percent))

    if CGDisplayIsBuiltin(id) != 0 {
        guard let set = setNativeBrightness else { return "нет DisplayServicesSetBrightness" }
        guard set(id, Float(clamped) / 100) == 0 else { return "DisplayServices отказал" }
        if persist { rememberBrightness(id, clamped) }
        return nil
    }

    guard let service = avService(for: id) else { return "монитор не отвечает по DDC" }
    // Шкала DDC — 0...100 у подавляющего большинства мониторов.
    guard writeDDC(service, command: vcpBrightness, value: UInt16(clamped)) else {
        return "запись по I2C не прошла"
    }
    if persist { rememberBrightness(id, clamped) }
    return nil
}

/// Последнее известное значение. Прочитать текущее по DDC удаётся редко —
/// мониторы отвечают пустым кадром, — поэтому помним своё.
public func brightness(_ id: CGDirectDisplayID) -> Int {
    if CGDisplayIsBuiltin(id) != 0, let get = getNativeBrightness {
        var value: Float = -1
        if get(id, &value) == 0, value >= 0 { return Int((value * 100).rounded()) }
    }
    return loadSnapshots()[id]?.brightness ?? 50
}

public func rememberBrightness(_ id: CGDirectDisplayID, _ percent: Int) {
    var snapshots = loadSnapshots()
    guard var snapshot = snapshots[id] else { return }
    snapshot.brightness = percent
    snapshots[id] = snapshot
    saveSnapshots(snapshots)
}
