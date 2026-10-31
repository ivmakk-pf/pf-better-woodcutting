# Configuration

Every setting lives in `Permafrost\Binaries\Win64\ue4ss\Mods\BetterWoodcutting\config.lua`, written the first time you run the game with the mod installed. Edit it with any text editor while the game is closed. Changes apply at the next game start. A mod update keeps this file.

| Setting | Default | Values | What it does |
|---|---|---|---|
| `log_pickup` | `true` | `true`, `false` | Puts the logs of a felled tree into the inventory of the player who cut it. `false` leaves the logs on the ground, as in the game without the mod. |
| `pickup_range_m` | `15` | `1` to `100` | How close, in metres, the player who cut the tree must be to its stump when the tree breaks into logs. Further away, the logs stay on the ground. |
| `nearby_range_m` | `5` | `0` to `20` | When you pick up a log by hand, the other logs this close to it, in metres, come with it. `0` turns this off. |
| `hit_assist` | `true` | `true`, `false` | Gives an axe swing at a tree that does not hit one normal hit, and starts the next swing when the game breaks off a held chop. `false` leaves the swings as in the game without the mod. |
| `verbose` | `false` | `true`, `false` | Writes extra lines to `UE4SS.log` for troubleshooting. Keep it off in normal play. |

A value outside its range applies as the nearest limit. A value of the wrong type applies as the default. When the game cannot read the file (for example after a typo), every setting applies as the default, and the file stays as it is.
