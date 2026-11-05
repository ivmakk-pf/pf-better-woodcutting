# Copilot code-review instructions

This repo is a UE4SS Lua mod for *Permafrost*, a co-op Unreal Engine 5.4 game. The mod runs in UE4SS (Lua 5.4): it hooks game UFunctions with `RegisterHook`, watches new objects with `NotifyOnNewObject`, and reads and writes UObject properties at runtime. Review with these traps in mind; a general Lua review misses most of them.

## This mod

BetterWoodcutting has three features, each in its own folder of `Scripts/bw/` and each behind a config switch. In each folder, `feature.lua` talks to the game and `logic.lua` is game-free. `Scripts/bw/core/` holds the config and the shared context, and `Scripts/bw/paths.lua` the full class paths. The specs in `tests/` run with busted and fake UE4SS globals (`tests/fakes.lua`), with an 80 % coverage limit.

- **Log pickup** (`bw/log_pickup/`): when a felled tree (`BP_ScavengeableTree_C`) breaks into logs (`BP_TrunkPart_C`), it picks up each log for the player who cut the tree through the game's own pickup (`BeginInteraction`), so the wood amount stays the game's. The nearby pickup reads a log list that the log watcher fills, never `FindAllOf`. Host side: every hook acts only where the tree or log has authority. Flag any log wood grant that bypasses the game's pickup (for example a direct `AddItemAmount`), and any change of `Wood Loot Count`.
- **Hit assist** (`bw/hit_assist/`, with the trace and the hit in `assist.lua`): an axe swing (`GA_Attack_MeleePrimary_C`) at a tree with no hit gets one hit through the weapon's own `Server Hit Check`, and a held attack that the game interrupts at a tree is restarted through the weapon's own `SGK ClientPrimaryAction(true)`, at most `MAX_RESTARTS` times in a row. It acts only for the locally controlled character with authority (solo and host), and never for a tree whose health is 0 or less (a stump).
- **Stump removal** (`bw/stump/`): with an axe in hand, `IsInteractionAllowed` of a stump (health exactly 0) says yes, and the stump's own action becomes a timed action of the interact key. At the end of the game's hold, a pre hook on the native `InteractionInterface:FinalizeInteraction` marks the stump (`CurrentHealth = -1`, kept in the save), gives the wood of one log with `AddItemAmount`, and hides the stump. The load hide hides each marked stump again after the game's own setup of the tree.

Invariants:

- **No game call inside a hook callback.** Every game call that the hit assist makes (`Server Hit Check`, `ResetSwing`, the restart key-down) runs from `ExecuteInGameThread` or `ExecuteWithDelay`. A `Server Hit Check` call made directly inside a montage event callback froze the game. Flag any new direct call.
- **One hit per swing.** A check acts only for the newest swing, never within `MIN_HIT_INTERVAL_S` of the tree's last damage, and never when the game's own hit landed after the swing start. Flag a change that can give a swing a second hit.
- **Trees only.** A swing at anything but a standing tree (a rock, an animal, a stump) is never assisted or restarted.
- **Blueprint hook order.** In this UE4SS build a Blueprint hook callback runs after the function body, so a nested call's callback runs first. The swing tracking relies on this order.
- **FinalizeInteraction reads no parameter.** The game calls it with no parameter buffer, and a `get()` there crashed the game natively. The hook acts on the stump of the last look-at, when the HUD's current action is `BW_RemoveStump`. Flag any parameter read in that callback.
- **The wood item is in memory before `AddItemAmount`.** The call loads its item synchronously, which can deadlock while the world streams. Flag a removal path without the `Conv_SoftObjectReferenceToObject` check, and any synchronous load.
- **No player lookup.** `UEHelpers.GetPlayer` walks the object array (`FindAllOf`). The stump feature takes the local player from its character watcher, and the hit assist from the ability. Flag a new `GetPlayer` or `GetPlayerController` call.

## UE4SS traps

- **Object life.** A UObject can be destroyed at any time. Flag a stored object reference that is used without an `IsValid()` check.
- **Hook callbacks must not break the game.** Each callback body runs in `pcall`, and an error logs once. Flag a callback without `pcall`, and a log call in a per-call path with no once-only guard.
- **Blueprint hooks.** A Blueprint UFunction (`/Game/...`) exists only after its asset loads. A hook registers at the first moment that a live object proves its class is in memory: a new object of that class (checked by its class name), or a hook whose `self` is one. Flag a `RegisterHook` on a `/Game/` path with no such proof.
- **Lookups need proof.** `StaticFindObject` of an object that is not in memory walks the whole object array, and `FindAllOf` and `FindFirstOf` always walk it. A walk while the world streams can read a half-made object: a native crash that `pcall` does not catch. Flag a lookup of a `/Game/` object on a timer (`LoopAsync`, `LoopInGameThreadWithDelay`, `ExecuteWithDelay`), at each map load, in a `NotifyOnNewObject` path for objects of another class, or in a per-frame hook. The safe forms: the class name or the class chain (`GetSuperStruct`) of a live object, an object from a hook parameter, and `Conv_SoftObjectReferenceToObject` of a soft reference. A `/Script/` class or `Default__` object is always in memory (a hash hit).
- **Full paths.** `RegisterHook` and `NotifyOnNewObject` need the full path (`/Script/Permafrost.Class:Function`, `/Game/.../BP_X.BP_X_C`). Flag a short class name.
- **Parameters.** Hook parameters are `RemoteUnrealParam`: read with `:get()`, write with `:set()`. Flag a direct use of the parameter as a value.
- **New objects.** The properties of an object from `NotifyOnNewObject` are not set at the callback. Flag a property read in that callback with no deferral.
- **Game thread.** Key bind and `LoopAsync` callbacks run outside the game thread. Flag UObject work there that is not inside `ExecuteInGameThread`.
- **Native crashes.** `pcall` does not catch a native crash. Flag a read of a whole struct or of soft object fields when the code needs only one field.
- **The Lua `debug` library.** Flag a local named `debug`, `print`, or another standard name that hides a library.

## Multiplayer

- **Side.** A `SERVER_` function body, `AUTHORITY_` functions, and inventory grants run on the host. Flag code that changes shared state (damage, loot, inventory) on a client, and host logic with no `HasAuthority()` check where both sides run the code.
- **Multiplayer kind.** The README states who must install the mod (Local only, Host, Every player). Flag a change that moves code to the other side without a README update.

## Performance

- Flag `FindAllOf`, `FindFirstOf`, `StaticFindObject`, string building, or table building in a tick hook, a `LoopAsync` with a short interval, or a hook of a function that runs often.

## Compatibility

- The mod must work with the vanilla game and with the mods named in the README. Flag a write of a game property that another named mod also writes, and an inventory grant that bypasses the game's own pickup path.

## Structure and tests

- **Pure logic is separated and tested.** Logic that does not need the running game lives in the `logic.lua` of its feature folder (`Scripts/bw/<feature>/logic.lua`), with no UE4SS global and no UObject, tested under `tests/<feature>/`. Flag new pure logic in a hook callback, and new pure logic with no test.
- **Game-facing code has glue specs.** The specs of `feature.lua` use the fakes of `tests/fakes.lua`, which dispatch new objects along the class chain as UE4SS does and count each `/Game/` lookup and each `FindAllOf`. Run `busted` from the repo root. Flag a feature change with no spec.
- **One function for each hook target,** named `<feature>On<Target>`.

## Release and config hygiene

- **Verbose ships off.** The `verbose` default is `false`. Debug lines go behind it; without it only the load line, warnings, and errors log.
- **The mod folder name never changes.** It is the `ue4ss\Mods\` folder and the home of the player's `config.lua`. Flag any rename.
- **The config file belongs to the player.** The mod writes `config.lua` only when it is missing. Flag code that overwrites it, and a `config.lua` in the repo or the zip.
- **The version** is the `VERSION` constant in `Scripts/main.lua`, printed in the load line.
- **No committed package output.** Flag `dist/` or a zip in the diff.
- **No game content.** Flag a header pasted from the UE4SS dump or an extracted game asset.
- **Changelog matches the change.** A player-visible change adds an `[Unreleased]` entry to `CHANGELOG.md` in player-facing wording. An internal-only refactor gets none.
