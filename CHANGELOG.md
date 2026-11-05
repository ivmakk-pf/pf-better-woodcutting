# Changelog

All notable changes to this mod are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this mod uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-11-05

### Added

- Stump removal: with an axe in hand, hold the interact key at a tree stump to remove it and get the Wood of one log.

### Fixed

- The game no longer crashes at random while the world loads, for example when you load a save or when new areas load as you travel.
- The hit assist helps from your first swing at a tree. Before, your first swings in a game session could get no help.
- When two trees fall at almost the same moment, the logs of each tree go to the player who cut that tree.

## [1.0.0] - 2026-10-31

### Added

- Log pickup: the logs of a felled tree go into the inventory of the player who cut it, within 15 m of the stump, with the game's own Wood amount.
- Nearby logs: a log picked up by hand brings the other logs within 5 m of it.
- Hit assist: an axe swing at a tree that does not hit gets one normal hit, also at the edge of the prompt range and right against the tree.
- Hold to chop: a held attack that the game breaks off at a tree starts again, at most 2 times in a row.
- `config.lua` with a switch for each feature and the two ranges.
