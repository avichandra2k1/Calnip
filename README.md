# Calnip

A keyboard-first quick-entry launcher for Apple Calendar.

Press a hotkey, type `lunch with sam 12-1 tom >work`, hit return. The event is on your calendar.

<!-- TODO: hero screenshot/GIF: docs/hero.png -->

## Features

- **Natural language input** with live token highlighting: times, ranges, days, dates, recurrence, calendars
- **Day timeline** in the panel: your events as colored blocks, a ghost preview of what you're typing, a now line
- **Conflict warnings** while you type, before you save
- **Recurring events**: `gym every weekday at 4`, `standup every monday till dec 20`
- **Calendar switching**: `>work` in the text, or `⌘1-9`, or click
- **Inline editing**: select any event with arrow keys, `⌘E`, edit it in the same natural language
- **Day browsing**: arrow through days like a mini calendar
- Liquid Glass or opaque panel, light and dark mode, configurable hotkeys

## Install

```sh
brew install avichandra2k1/tap/calnip
```

Or download `Calnip.zip` from the [latest release](https://github.com/avichandra2k1/Calnip/releases) and drop it in Applications.

Requires macOS 26 (Tahoe). On first use, Calnip asks for calendar access.

## Language

| Type | Result |
| --- | --- |
| `coffee 2pm` | Today at 2:00 PM, default duration |
| `sync 2:30-4` | Today, 2:30 to 4:00 PM |
| `lunch 12-1 tom` | Tomorrow, noon to 1 PM |
| `dentist tuesday` | Next Tuesday, all day |
| `flight in 2 days`, `party aug 27`, `bills 27th` | That day |
| `errands` | All-day event today |
| `gym every weekday at 4` | Recurring, 4 PM on weekdays |
| `jog every 2 days till fri` | Recurring with an end date |
| `review 3pm >work` | 3 PM in the calendar matching "work" |

## Keys

| Key | Action |
| --- | --- |
| `⌥ Space` | Open or close the panel (configurable) |
| `↩` | Add the event |
| `⌘1-9` | Switch target calendar |
| `↓` then `↑↓` | Select events |
| `← →` | Browse days |
| `⌘E` | Edit the selected event (configurable) |
| `⌘,` | Settings |
| `esc` | Close |

## Build from source

```sh
./build.sh && open Calnip.app
```

Swift Package, no Xcode project. Requires Xcode 26 command line tools.

## Privacy

Local-only. Calnip talks directly to Apple Calendar through EventKit. Nothing leaves your Mac.

## License

[MIT](LICENSE)
