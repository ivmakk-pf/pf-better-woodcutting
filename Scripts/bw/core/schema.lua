-- The one source of the config keys, defaults, ranges, and comments.
-- Its own file, so the tests can read it without the UE4SS globals of main.lua.
---@type ConfigEntry[]
return {
    {
        key = "log_pickup",
        default = true,
        comment = "Pick up the logs of a felled tree for the player who cut it.",
    },
    {
        key = "pickup_range_m",
        default = 15,
        min = 1,
        max = 100,
        comment = "The player must be this close to the tree stump when the trunk breaks, in metres.",
    },
    {
        key = "nearby_range_m",
        default = 5,
        min = 0,
        max = 20,
        comment = "A log picked up by hand also picks up the other logs this close to it, in metres. 0 turns this off.",
    },
    {
        key = "hit_assist",
        default = true,
        comment = "An axe swing at a tree that does not hit gets one hit, also at the prompt edge or against the trunk; a held attack goes on after the game interrupts it.",
    },
    {
        key = "stump_removal",
        default = true,
        comment = "Remove a tree stump: look at it with an axe in hand and hold the interact key. You get the wood of one log, and the stump stays gone.",
    },
    {
        key = "stump_hold_s",
        default = 2,
        min = 0.5,
        max = 10,
        comment = "How long to hold the interact key to remove a stump, in seconds. The game adds about 1 s before the progress starts.",
    },
    { key = "verbose", default = false, comment = "Extra log lines in UE4SS.log. Keep off in normal play." },
}
