![version](https://img.shields.io/badge/version-1.0.1-blue)

# Better Woodcutting

Feel like a true lumberjack: fell a tree and its Wood lands straight in your backpack.

Some swings also do nothing when you stand at the edge of reach or right against the tree. This mod gives those swings their hit, and it picks up the logs of each tree you fell.

I love archery and chopping trees in games, and in Permafrost arrows need a lot of Wood. But chopping here felt bad: a swing only hits when you stand almost perfectly in front of the tree, with the distance right to the millimeter and the angle right to the degree. And on the mountain slopes the logs roll away, so I chased each one down the hill. Every Wood restock felt like a punishment. This mod is my fix for that.

## Features

- **Log pickup**: when a tree you cut breaks into logs, they go straight into your inventory, if you stand within 15 m of the stump. You get the same Wood as by hand. If the inventory is full, the rest stays on the ground.
- **Nearby logs**: pick up one log by hand, and the other logs within 5 m come with it.
- **Hit assist**: your axe swings now deal damage even from the edge of reach or right against the tree. Each swing still gives one normal hit.

## Save safety

The mod stores nothing in your save, so you can remove it at any time.

## Multiplayer

Tested only in single player. In co-op, only the host needs the mod: the log pickup then works for every player. The hit assist helps only the host's own swings. A player who joins gets no hit assist, with or without the mod.

## Works well with

- [Custom Mining Woodcutting Yield](https://www.nexusmods.com/permafrost/mods/12): changes how much Wood each log gives. The log pickup gives you that changed amount.
- [Custom Stack Size](https://www.nexusmods.com/permafrost/mods/5): bigger stacks. With this mod you collect Wood much faster, and a full inventory leaves the rest on the ground, so more room in each stack helps.

## Requirements

- Permafrost (Early Access), the update of 30 October 2026 or later.
- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest), the experimental build. The mod is tested with it, not with the older 3.0.1 release.

## Installation

1. Install UE4SS, if you do not have it yet: on the [UE4SS experimental page](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest), download the UE4SS zip (for example `UE4SS_v3.0.1-1196-g236adf26.zip`). Extract it into the `Permafrost\Binaries\Win64` folder inside the game folder.
2. Extract this mod's zip into the game folder (the folder with Permafrost.exe). The mod lands in Permafrost\Binaries\Win64\ue4ss\Mods. Full path example:
   `C:\Program Files (x86)\Steam\steamapps\common\Permafrost\Permafrost\Binaries\Win64\ue4ss\Mods\BetterWoodcutting`

## Uninstall

Delete the `BetterWoodcutting` folder from the `ue4ss\Mods` folder.

## Configuration

To change mod settings, edit `ue4ss\Mods\BetterWoodcutting\config.lua` while the game is closed (see [CONFIG.md](CONFIG.md) for every setting). Changes apply at the next game start.

## Development

The logic files (`Scripts/*_logic.lua`) have unit tests that run with plain Lua 5.4, from the repo root:

```
lua tests/run.lua
```

`./package.ps1` makes the install zip in `dist/`.

## License

Licensed under the GNU General Public License v3.0. Copyright (C) 2026 ivmakk.

Do not reupload this mod or a changed copy without credit and a link to this repository.
