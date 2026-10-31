# Better Woodcutting

Feel like a true lumberjack: fell a tree and its Wood lands straight in your backpack.

Some swings also do nothing when you stand at the edge of reach or right against the tree. This mod gives those swings their hit, and it picks up the logs of each tree you fell.

## Features

- **Log pickup**: when a felled tree breaks into logs, the logs go into the inventory of the player who cut the tree, if that player is within 15 m of the stump. You get the same Wood as when you pick the logs up by hand, also with a mod that changes the Wood per log. When the inventory is full, the rest of the Wood stays on the ground.
- **Nearby logs**: when you pick up a log by hand, the other logs within 5 m of it come with it. This helps with logs left after a full inventory and logs of a tree that fell far from you.
- **Hit assist**: an axe swing at a tree that does not hit gets one normal hit, with the game's damage, durability, and effects. It works at the edge of the prompt range and when you stand right against the tree. The assisted hit lands a moment later than a normal hit, about 0.8 s after the swing starts. A swing at a rock or anything else stays as it is.
- **Hold to chop**: when you hold the attack button and the game breaks off the chop, the mod starts the next swing, at most 2 times in a row.

## Fair play

- Each swing costs the same stamina as without the mod, and each hit costs the same durability.
- The mod adds no Wood: every log goes through the game's own pickup.
- The hit assist adds no hit within 1.1 s of the last hit on that tree, so clicking fast does not chop faster than holding the button.

## Save safety

The mod stores nothing in your save, so you can remove it at any time.

## Multiplayer

Tested only in single player. In co-op, only the host needs the mod: the log pickup then works for every player. The hit assist and hold to chop help only the host's own swings. A player who joins gets no hit assist, with or without the mod.

## Works well with

- [Custom Mining & Woodcutting Yield](https://www.nexusmods.com/permafrost/mods/12): changes how much Wood each log gives. The log pickup gives you that changed amount.
- [Custom Stack Size](https://www.nexusmods.com/permafrost/mods/5): bigger stacks. With this mod you collect Wood much faster, and a full inventory leaves the rest on the ground, so more room in each stack helps.

## Requirements

- Permafrost (Early Access), the update of 30 October 2026 or later.
- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS/releases) 3.0.1 or later.

## Installation

1. Install [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS/releases).
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
