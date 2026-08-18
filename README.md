# dspl

Включение и выключение мониторов на macOS из терминала. Одна из немногих вещей,
ради которых обычно покупают BetterDisplay Pro.

Гасит встроенный экран MacBook при открытой крышке — клавиатура, трекпад и
динамики продолжают работать. Так же управляет любым внешним монитором.

## Установка

```bash
git clone https://github.com/nvinnikov/dspl-tool.git
cd dspl-tool
bash install.sh
```

Нужны Command Line Tools (`xcode-select --install`). Больше зависимостей нет.

## Использование

```bash
dspl list                # все известные мониторы
dspl off builtin         # выключить встроенный экран
dspl on builtin          # включить обратно
dspl toggle builtin      # переключить
dspl off 2               # то же самое по номеру из колонки #
dspl off "Kuycon G27-X"  # или по имени
dspl reset               # включить всё обратно
```

Монитор указывается тремя способами: ролью (`builtin` / `external`), порядковым
номером из колонки `#` или именем. Колонка `ID` — системный `CGDirectDisplayID`,
она только для справки: он бывает вида `724045334` и меняется при
переподключении, поэтому аргументом не принимается.

```
$ dspl list
#  STATE  NAME              RESOLUTION  ID
1  OFF    Built-in Display  1512x982    1
2  on     Kuycon G27-X      2560x1440   2
```

Номера назначаются один раз и хранятся в state-файле, между запусками не
прыгают. Но если физически поменять состав мониторов, они сдвинутся — поэтому в
скриптах и на хоткее надёжнее `builtin` / `external`.

### Подтверждение с откатом

`off` и `toggle` после выключения ждут подтверждения и откатываются, если его нет:

```
$ dspl off builtin
выключен: Built-in Display. Оставить? [y/N], откат через 5с
```

Молчание или любой ответ кроме `y` возвращает монитор. Страховка на случай, если
погас не тот экран — терминал может оказаться на нём, и ответить придётся вслепую.

- `-y` / `--yes` — не спрашивать.
- `DSPL_TIMEOUT=10` — свой таймаут в секундах.

Подтверждение автоматически пропускается, когда stdin не терминал — иначе запуск
из Raycast или Karabiner висел бы вечно.

### Хоткей

Raycast → Script Commands, или Karabiner `shell_command`:

```bash
~/bin/dspl toggle builtin
```

## Если что-то пошло не так

```bash
dspl reset
```

Наберётся вслепую и вернёт все мониторы. Состояние применяется через
`CGCompleteDisplayConfiguration(.forSession)`, так что перезагрузка тоже всё
восстановит.

## How to: с нуля до хоткея

### 1. Поставить

```bash
git clone https://github.com/nvinnikov/dspl-tool.git
cd dspl-tool
bash install.sh
```

Если `install.sh` дописал `~/bin` в `PATH` — перезапусти терминал или выполни
`source ~/.zshrc`. Проверка:

```bash
dspl list
```

Должен появиться список мониторов. Если вместо него `command not found` — зови
полным путём `~/bin/dspl` или разберись с `PATH`.

### 2. Понять, какой монитор какой

```bash
$ dspl list
1	OFF	Built-in Display      	1512x982
2	on 	Kuycon G27-X          	2560x1440
```

Колонки: id, состояние, имя, разрешение. `Built-in Display` — экран самого
MacBook. Дальше можно обращаться либо по id (`1`), либо по имени роли
(`builtin`, `external`).

### 3. Первый раз — на внешнем мониторе

Начни с внешнего, а не со встроенного: если что-то пойдёт не так, у тебя
останется экран, на котором видно терминал.

```bash
dspl off external
```

Монитор погаснет и появится вопрос. Ничего не нажимай — через 5 секунд он
вернётся сам. Так ты убедишься, что откат работает, ничем не рискуя.

### 4. Погасить экран MacBook

```bash
dspl off builtin
```

Картинка на встроенном пропадёт, окна переедут на внешний. Клавиатура, трекпад
и динамики продолжают работать — это не clamshell, крышку закрывать не нужно.

Устраивает — жми `y` и Enter. Не устраивает или что-то выглядит сломанным —
просто подожди, всё вернётся.

Вернуть вручную:

```bash
dspl on builtin
```

### 5. Повесить на хоткей

Одна команда для «туда-обратно»:

```bash
dspl toggle builtin
```

**Raycast.** Положи файл в свою папку Script Commands:

```bash
#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Toggle built-in display
# @raycast.mode silent
~/bin/dspl toggle builtin
```

Готовый лежит в репозитории: `raycast/toggle-builtin-display.sh`. Добавь папку
`raycast` в Raycast → Extensions → Script Commands → Add Directory, потом назначь
хоткей на саму команду.

**Karabiner-Elements.** В `complex_modifications` действие:

```json
{ "shell_command": "$HOME/bin/dspl toggle builtin" }
```

**Shortcuts / Automator.** Действие «Run Shell Script» с той же строкой.

Подтверждение при запуске с хоткея не спрашивается — stdin там не терминал,
и утилита это понимает. Если хочешь вернуть экран, жми хоткей ещё раз.

### 6. Если экран пропал и непонятно что делать

Набери вслепую:

```bash
dspl reset
```

Вернёт все мониторы. Не помогло — перезагрузка: состояние ставится как
`.forSession` и после ребута сбрасывается само.

## Как это устроено

Публичного API для отключения дисплея у macOS нет. Утилита резолвит приватный
символ `SLSConfigureDisplayEnabled` из SkyLight (с фолбэком на
`CGSConfigureDisplayEnabled` из CoreGraphics) и вызывает его внутри обычной
`CGBeginDisplayConfiguration` / `CGCompleteDisplayConfiguration`. Тем же
механизмом пользуется BetterDisplay.

Отсюда же оговорка: приватный символ Apple может убрать в любой версии macOS.
Тогда `dspl` честно сообщит, что не нашёл его, а не сломается молча.

Имена мониторов читаются из IORegistry (`DisplayAttributes/ProductAttributes`)
и сопоставляются с дисплеем по паре vendor/product из EDID.

Выключенный дисплей пропадает из `CGGetOnlineDisplayList`, поэтому последний
известный список сохраняется в `~/.local/state/dspl.json` — иначе `list` не
показал бы погашенный монитор, а `reset` не смог бы его вернуть.

Проверено на macOS 15 / Apple Silicon (M3 Pro).
