// DsplBar — иконка в статус-баре поверх DisplayCore.
// Логики работы с мониторами здесь нет, только меню и подтверждение.

import AppKit
import ServiceManagement

let rollbackSeconds = 15

// Callback WindowServer срабатывает на подключение и отключение железа даже
// тогда, когда AppKit-уведомление не доходит. Ссылку на делегата держим глобально:
// в C-функцию контекст объекта не передать.
weak var sharedDelegate: AppDelegate?

func displayReconfigured(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags,
                         _ context: UnsafeMutableRawPointer?) {
    logEvent("cg-callback display=\(display) flags=\(flags.rawValue) \(displaysDigest())")
    DispatchQueue.main.async { sharedDelegate?.displayConfigurationChanged() }
}

// У приложения нет собственного .icns, поэтому в алертах показываем SF Symbol.
// Символы приходят и уходят между версиями macOS — отсюда fallback.
func symbolIcon(_ name: String, fallback: String) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
    for candidate in [name, fallback] {
        if let image = NSImage(systemSymbolName: candidate, accessibilityDescription: nil) {
            return image.withSymbolConfiguration(config)
        }
    }
    return nil
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var watchdog: Timer?
    private var sleeping = false
    private var appNapToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        // Мониторы могут пропасть и появиться помимо нас — держим иконку честной.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep),
                              name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake),
                              name: NSWorkspace.didWakeNotification, object: nil)

        // Без этого macOS усыпляет фоновое приложение и растягивает интервал
        // таймера на десятки секунд — сторож просыпается уже после аварии.
        appNapToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Следим, чтобы не остаться без активных дисплеев"
        )

        sharedDelegate = self
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil)

        // Уведомление может не прийти, а остаться без картинки — дорого.
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.rescueIfBlind(source: "timer")
        }

        logEvent("запуск \(displaysDigest())")
    }

    // MARK: - Сторож

    // Единственный способ остаться без активных дисплеев — физически отключить
    // тот, что работал: погасить последний включённый мы не даём. Значит это
    // авария, и надо вернуть всё, что помним.
    @objc private func screenParametersChanged() {
        logEvent("screen-params \(displaysDigest())")
        displayConfigurationChanged()
    }

    func displayConfigurationChanged() {
        updateIcon()
        rescueIfBlind(source: "config")
    }

    @objc private func willSleep() {
        sleeping = true
        logEvent("сон")
    }

    @objc private func didWake() {
        logEvent("пробуждение \(displaysDigest())")
        // Дисплеи возвращаются не мгновенно; сторож в этот момент вернул бы
        // экран, который человек специально погасил.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.sleeping = false }
    }

    private func rescueIfBlind(source: String) {
        guard activeDisplayCount() == 0 else { return }
        logEvent("ноль дисплеев (\(source)), sleeping=\(sleeping) \(displaysDigest())")
        guard !sleeping else { return }

        // Подтверждаем: при засыпании и переключении режимов ноль дисплеев
        // бывает кратковременно и сам проходит.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            guard !self.sleeping, activeDisplayCount() == 0 else {
                logEvent("отбой, картинка вернулась сама \(displaysDigest())")
                return
            }
            let error = resetAllDisplays()
            logEvent("спасение: \(error ?? "ок") \(displaysDigest())")
            self.updateIcon()
        }
    }

    // MARK: - Иконка

    // Значок показывает, есть ли выключенные мониторы, чтобы не открывать меню.
    @objc private func updateIcon() {
        let hasDisabled = listDisplays().contains { !$0.isActive }
        // display.slash в SF Symbols нет — перечёркнутый прямоугольник ближе всего
        // по смыслу «экран выключен».
        let name = hasDisabled ? "rectangle.slash" : "display"

        if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Мониторы") {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.title = ""
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = hasDisabled ? "▨" : "▣"
        }
    }

    // MARK: - Меню

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        let displays = listDisplays()
        let activeCount = displays.filter { $0.isActive }.count

        for display in displays {
            let item = NSMenuItem(
                title: "\(display.name)  —  \(display.resolution)",
                action: #selector(toggleDisplay(_:)), keyEquivalent: ""
            )
            item.target = self
            item.state = display.isActive ? .on : .off
            item.representedObject = display.number
            // Последний включённый гасить нельзя — гасим меню, а не экран.
            item.isEnabled = !(display.isActive && activeCount == 1)
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let reset = NSMenuItem(title: "Включить все", action: #selector(resetAll), keyEquivalent: "")
        reset.target = self
        reset.isEnabled = displays.contains { !$0.isActive }
        menu.addItem(reset)

        let login = NSMenuItem(title: "Запускать при входе",
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Действия

    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? Int,
              let display = resolveDisplay("\(number)") else { return }

        if display.isActive {
            if let error = setDisplay(display.id, enabled: false) {
                report("Не удалось выключить \(display.name)", error)
                return
            }
            confirmOrRollback(display)
        } else if let error = setDisplay(display.id, enabled: true) {
            report("Не удалось включить \(display.name)", error)
        }
        updateIcon()
    }

    @objc private func resetAll() {
        if let error = resetAllDisplays() { report("Не удалось включить мониторы", error) }
        updateIcon()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            report("Не удалось изменить автозапуск", error.localizedDescription)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Подтверждение с откатом

    // В CLI на этот вопрос отвечают вслепую — здесь кнопка видна на оставшемся
    // экране, так что достаточно на неё посмотреть.
    private func confirmOrRollback(_ display: DisplayInfo) {
        let alert = NSAlert()
        alert.icon = symbolIcon(display.isBuiltin ? "laptopcomputer.slash" : "rectangle.slash",
                                fallback: "display")
        alert.messageText = "\(display.name) выключен"
        alert.addButton(withTitle: "Подтвердить")
        alert.addButton(withTitle: "Отменить")

        var secondsLeft = rollbackSeconds
        alert.informativeText = "Вернём через \(secondsLeft) с."

        let timer = Timer(timeInterval: 1, repeats: true) { timer in
            secondsLeft -= 1
            if secondsLeft <= 0 {
                timer.invalidate()
                NSApp.abortModal()
            } else {
                alert.informativeText = "Вернём через \(secondsLeft) с."
            }
        }
        // .common, иначе таймер не тикает, пока крутится модальный runloop.
        RunLoop.main.add(timer, forMode: .common)

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        timer.invalidate()

        guard response != .alertFirstButtonReturn else { return }
        if let error = setDisplay(display.id, enabled: true) {
            report("Откат не удался", error)
        }
    }

    private func report(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.icon = symbolIcon("display.trianglebadge.exclamationmark", fallback: "display")
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // без иконки в доке
app.run()
