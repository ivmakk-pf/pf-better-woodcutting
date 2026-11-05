![version](https://img.shields.io/badge/version-1.1.0-blue) ![coverage](https://img.shields.io/badge/coverage-98%25-brightgreen)

# Better Woodcutting

Feel like a true lumberjack: fell a tree and its Wood lands straight in your backpack.

Some swings also do nothing when you stand at the edge of reach or right against the tree. This mod gives those swings their hit, picks up the logs of each tree you fell, and lets you clear the stumps from the place of your base.

I love archery and chopping trees in games, and in Permafrost arrows need a lot of Wood. But chopping here felt bad: a swing only hits when you stand almost perfectly in front of the tree, with the distance right to the millimeter and the angle right to the degree. And on the mountain slopes the logs roll away, so I chased each one down the hill. Every Wood restock felt like a punishment. This mod is my fix for that.

## Features

- **Log pickup**: when a tree you cut breaks into logs, they go straight into your inventory, if you stand within 15 m of the stump. You get the same Wood as by hand. If the inventory is full, the rest stays on the ground.
- **Nearby logs**: pick up one log by hand, and the other logs within 5 m come with it.
- **Hit assist**: your axe swings now deal damage even from the edge of reach or right against the tree. Each swing still gives one normal hit.
- **Stump removal**: with an axe in hand, look at a tree stump from up to 2.5 m away and hold the interact key (F by default) at the "Remove stump" prompt, as you hold it to skin an animal. When the progress fills (about 3 s), the stump goes and you get the Wood of one log. What does not fit in your inventory drops, as for a log you pick up. The stump stays gone after you load the save.

## Save safety

The mod marks each stump that you remove in your save. Nothing else goes into the save. You can remove the mod at any time: the stumps that you removed then show again as normal stumps.

## Multiplayer

Tested only in single player. In co-op, only the host needs the mod: the log pickup then works for every player. The hit assist helps only the host's own swings. A player who joins gets no hit assist, with or without the mod. Only the host can remove a stump, and a player who joins still sees a removed stump until they load the world again.

## Works well with

- [Custom Mining Woodcutting Yield](https://www.nexusmods.com/permafrost/mods/12): changes how much Wood each log gives. The log pickup gives you that changed amount.
- [Custom Stack Size](https://www.nexusmods.com/permafrost/mods/5): bigger stacks. With this mod you collect Wood much faster, and a full inventory leaves the rest on the ground, so more room in each stack helps.

## Requirements

- Permafrost (Early Access), the update of 30 October 2026 or later.
- [UE4SS for Permafrost](https://www.nexusmods.com/permafrost/mods/42), the UE4SS build that the mod is tested with.

## Installation

1. Install [UE4SS for Permafrost](https://www.nexusmods.com/permafrost/mods/42).
2. Extract this mod's zip into the game folder (the folder with Permafrost.exe). The mod lands in Permafrost\Binaries\Win64\ue4ss\Mods. Full path example for Steam:
   `C:\Program Files (x86)\Steam\steamapps\common\Permafrost\Permafrost\Binaries\Win64\ue4ss\Mods\BetterWoodcutting`

## Uninstall

Delete the `BetterWoodcutting` folder from the `ue4ss\Mods` folder.

## Configuration

To change mod settings, edit `ue4ss\Mods\BetterWoodcutting\config.lua` while the game is closed (see [CONFIG.md](CONFIG.md) for every setting). Changes apply at the next game start.

## Development

The code is in `Scripts/bw/`: `core/` holds the config and the shared helpers, `paths.lua` the class paths, `hit_assist/` the hit assist (`assist.lua` the trace and the hit), and `log_pickup/` the log pickup. In each feature folder, `feature.lua` talks to the game, and `logic.lua` is game-free. The specs in `tests/` run with [busted](https://lunarmodules.github.io/busted/) on Lua 5.4, with fake UE4SS globals (`tests/fakes.lua`). They need the rocks `busted` and `luafilesystem` (and `luacov` for the coverage). From the repo root:

```
busted
busted --coverage
```

`./package.ps1` makes the install zip in `dist/`.

## License

Licensed under the GNU General Public License v3.0. Copyright (C) 2026 ivmakk.

Do not reupload this mod or a changed copy without credit and a link to this repository.
