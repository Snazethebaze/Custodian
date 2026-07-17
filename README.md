# Custodian

**A modular, customizable, cross-class resource & buff HUD for World of Warcraft.**
Bars and icons you can bind to anything, snap together into groups, and move as one.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## What it is

Custodian is an at-a-glance HUD: resource bars, buff and imbue reminders, and pre-combat
checks — tuned per class and spec. You build it yourself from bars and icons, bind each one
to whatever you want to watch, and drag them together into groups.

It watches what you're meant to keep up **three ways**:

- **Live** — resources, buffs, and cooldowns it can read moment to moment. Bars fill, timers
  tick, and a reminder clears the instant the buff lands.
- **Pre-combat** — some things (weapon imbues, poisons, shields) become hidden from addons once
  you're in combat. Custodian checks them *before* the pull and reminds you to top up; in a
  fight it holds quietly instead of nagging about something it can no longer see.
- **Manual (estimated)** — a few stacks can't be read at all, so it estimates by watching your
  casts (a builder adds one, a spender removes one). Right in the common case, resets when you
  leave combat, and can drift — a guide, not gospel.

## Features

- **Cross-class** — every class and power type; per-spec tuned.
- **Guided "Add widget" flow** — pick a resource, a maintained buff, a weapon oil, or search any
  spell; filter the list by spec.
- **Bars & icons** bindable to anything, grouped and moved together.
- **Reminders** — show a widget only when a buff is missing, a cooldown is ready, a value crosses
  a threshold, only while in a form, or only in combat.
- **Colour stops** — recolour a bar as it fills and optionally ping you at a threshold.
- **Segmented display** — combo points, runes, Maelstrom stacks, and charges as boxes/pips.
- **Share setups** — export any widget, folder, or class as a string and import it back.
- **Sounds & TTS**, a bundled texture/sound pack, and a movable minimap button.

## Install

- **CurseForge / the CurseForge app** — search for *Custodian* (recommended; auto-updates).
- **Manual** — download the latest release, unzip, and drop the `Custodian` folder into
  `World of Warcraft/_retail_/Interface/AddOns/`.

## Getting started

1. Open the panel: click the **minimap button**, or type `/cust`.
2. Hit **+ Add widget** and pick something to watch — one click adds it and drops you into
   **Move HUD** so you can place it.
3. Drag widgets on top of each other to **group** them; drag a group's handle to move it as one.
4. **Lock HUD** when you're happy.

Fine-tune anything by selecting it in the sidebar: what it tracks, how it looks, when it shows,
and how it's grouped.

### Slash commands

| Command | What it does |
|---|---|
| `/cust` | Open the settings panel |
| `/cust unlock` / `/cust lock` | Enter / leave Move HUD |
| `/cust minimap` | Show / hide the minimap button |
| `/cust reset` | Wipe and re-seed the default layout |

## Sharing setups

Right-click a widget, folder, or class in the sidebar to **export** it to a string, and use the
**Import** button to add someone else's — trackers, groups, and folders come across intact. It's a
safe, data-only format (no code execution on import).

## Contributing

Bug reports and ideas are welcome via [GitHub Issues](https://github.com/Snazethebaze/Custodian/issues).
Pull requests are welcome too.

## License

Released under the [MIT License](LICENSE).

## Author

Made by **Snazethebaze**. Questions or ideas? Find me on Discord: **Snazethebaze**.
