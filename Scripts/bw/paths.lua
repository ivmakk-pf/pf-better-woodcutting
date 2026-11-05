-- The full path of each class that a feature hooks, from the game dump (game/blueprints/).
-- No code looks a path up: in this UE4SS build a lookup of a class that is not in memory walks the
-- whole object array, and a walk while the world loads can crash the game. Each caller registers a
-- NotifyOnNewObject watcher on the path (which looks up nothing) and arms the hooks of the class
-- only from that watcher, when a new object proves that the class is in memory. RegisterHook then
-- resolves the function with a hash lookup.
return {
    GA_Attack_MeleePrimary_C = "/Game/Permafrost/Blueprints/GAS/GameplayAbilities/Items/GA_Attack_MeleePrimary.GA_Attack_MeleePrimary_C",
    BP_MasterMeleeWeapon_C = "/Game/SurvivalGameKitV2/Blueprints/Items/HoldableItems/BP_MasterMeleeWeapon.BP_MasterMeleeWeapon_C",
    BP_ScavengeableTree_C = "/Game/Permafrost/Blueprints/Interactions/Scavengable/BP_ScavengeableTree.BP_ScavengeableTree_C",
    BP_TrunkPart_C = "/Game/Permafrost/Blueprints/Interactions/LooseResource/Wood/BP_TrunkPart.BP_TrunkPart_C",
    UW_HUD_C = "/Game/Permafrost/UI/HUD/UW_HUD.UW_HUD_C",
    BP_SGKMasterCharacter_C = "/Game/SurvivalGameKitV2/Blueprints/Characters/BP_SGKMasterCharacter.BP_SGKMasterCharacter_C",
}
