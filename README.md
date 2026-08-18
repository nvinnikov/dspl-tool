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
dspl list                # все известные мониторы: id, состояние, имя, разрешение
dspl off builtin         # выключить встроенный экран
dspl on builtin          # включить обратно
dspl toggle builtin      # переключить
dspl off 2               # то же самое по id
dspl reset               # включить всё обратно
```

Вместо `builtin` / `external` можно указывать id из первой колонки `dspl list`.

```
$ dspl list
1	OFF	Built-in Display      	1512x982
2	on 	Kuycon G27-X          	2560x1440
```

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
