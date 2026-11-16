-- Gladdy-style target specialization inference data (WoW 3.3.5a).
-- Tables are keyed by uppercased localized spell name (via GetSpellInfo) and
-- map to the addon's spec tokens (State.lua classSpecs). Sources:
-- Gladdy's Constants_Wrath.lua (specBuffs / specSpells).
--
-- specBuffs: self-cast auras seen on the target (caster must be the target
-- or the target's pet). specSpells: spells cast by the target (combat log).
local addon = WMacroCompiler
local SpecData = { specBuffs = {}, specSpells = {} }
addon.SpecData = SpecData

local getSpellInfo = GetSpellInfo or function() return nil end

local function add(target, spellID, spec)
    local name = getSpellInfo(spellID)
    if name then
        target[string.upper(name)] = spec
    end
end

local buffs = {
    -- WARRIOR
    { 56638, "ARMS" }, -- Taste for Blood
    { 64976, "ARMS" }, -- Juggernaut
    { 57522, "ARMS" }, -- Enrage
    { 52437, "ARMS" }, -- Sudden Death
    { 46857, "ARMS" }, -- Trauma
    { 56112, "FURY" }, -- Furious Attacks
    { 29801, "FURY" }, -- Rampage
    { 46916, "FURY" }, -- Slam!
    { 50227, "PROTECTION" }, -- Sword and Board
    { 50720, "PROTECTION" }, -- Vigilance
    -- PALADIN
    { 20375, "RETRIBUTION" }, -- Seal of Command
    { 59578, "RETRIBUTION" }, -- The Art of War
    { 31836, "HOLY" }, -- Light's Grace
    { 53563, "HOLY" }, -- Beacon of Light
    { 54149, "HOLY" }, -- Infusion of Light
    -- ROGUE
    { 36554, "SUBTLETY" }, -- Shadowstep
    { 44373, "SUBTLETY" }, -- Shadowstep Speed
    { 36563, "SUBTLETY" }, -- Shadowstep DMG
    { 51713, "SUBTLETY" }, -- Shadow Dance
    { 31665, "SUBTLETY" }, -- Master of Subtlety
    { 14278, "SUBTLETY" }, -- Ghostly Strike
    { 51690, "COMBAT" }, -- Killing Spree
    { 13877, "COMBAT" }, -- Blade Flurry
    { 13750, "COMBAT" }, -- Adrenaline Rush
    { 14177, "ASSASSINATION" }, -- Cold Blood
    -- PRIEST
    { 47788, "HOLY" }, -- Guardian Spirit
    { 52800, "DISCIPLINE" }, -- Borrowed Time
    { 63944, "DISCIPLINE" }, -- Renewed Hope
    { 15473, "SHADOW" }, -- Shadowform
    { 15286, "SHADOW" }, -- Vampiric Embrace
    -- DEATHKNIGHT
    { 49222, "UNHOLY" }, -- Bone Shield
    { 49016, "BLOOD" }, -- Hysteria
    { 53138, "BLOOD" }, -- Abomination's Might
    { 55610, "FROST" }, -- Improved Icy Talons
    -- MAGE
    { 43039, "FROST" }, -- Ice Barrier
    { 74396, "FROST" }, -- Fingers of Frost
    { 57761, "FROST" }, -- Fireball! (Brain Freeze proc)
    { 11129, "FIRE" }, -- Combustion
    { 64346, "FIRE" }, -- Fiery Payback
    { 48108, "FIRE" }, -- Hot Streak
    { 54741, "FIRE" }, -- Firestarter
    { 55360, "FIRE" }, -- Living Bomb
    { 31583, "ARCANE" }, -- Arcane Empowerment
    { 44413, "ARCANE" }, -- Incanter's Absorption
    -- WARLOCK
    { 30302, "DESTRUCTION" }, -- Nether Protection
    { 63244, "DESTRUCTION" }, -- Pyroclasm
    { 54277, "DESTRUCTION" }, -- Backdraft
    { 47283, "DESTRUCTION" }, -- Empowered Imp
    { 34936, "DESTRUCTION" }, -- Backlash
    { 47193, "DEMONOLOGY" }, -- Demonic Empowerment
    { 64371, "AFFLICTION" }, -- Eradication
    -- SHAMAN
    { 57663, "ELEMENTAL" }, -- Totem of Wrath
    { 65264, "ELEMENTAL" }, -- Lava Flows
    { 51470, "ELEMENTAL" }, -- Elemental Oath
    { 52179, "ELEMENTAL" }, -- Astral Shift
    { 49284, "RESTORATION" }, -- Earth Shield
    { 53390, "RESTORATION" }, -- Tidal Waves
    { 30809, "ENHANCEMENT" }, -- Unleashed Rage
    { 53817, "ENHANCEMENT" }, -- Maelstrom Weapon
    { 63685, "ENHANCEMENT" }, -- Freeze (Frozen Power)
    -- HUNTER
    { 20895, "BEAST_MASTERY" }, -- Spirit Bond
    { 34471, "BEAST_MASTERY" }, -- The Beast Within
    { 75447, "BEAST_MASTERY" }, -- Ferocious Inspiration
    { 19506, "MARKSMANSHIP" }, -- Trueshot Aura
    { 64420, "SURVIVAL" }, -- Sniper Training
    -- DRUID
    { 24932, "FERAL" }, -- Leader of the Pack
    { 16975, "FERAL" }, -- Predatory Strikes
    { 24907, "BALANCE" }, -- Moonkin Aura
    { 24858, "BALANCE" }, -- Moonkin Form
    { 48504, "RESTORATION" }, -- Living Seed
    { 45283, "RESTORATION" }, -- Natural Perfection
    { 53251, "RESTORATION" }, -- Wild Growth
    { 33891, "RESTORATION" }, -- Tree of Life
}

local spells = {
    -- WARRIOR
    { 47486, "ARMS" }, -- Mortal Strike
    { 46924, "ARMS" }, -- Bladestorm
    { 23881, "FURY" }, -- Bloodthirst
    { 12809, "PROTECTION" }, -- Concussion Blow
    { 47498, "PROTECTION" }, -- Devastate
    { 46968, "PROTECTION" }, -- Shockwave
    { 50720, "PROTECTION" }, -- Vigilance
    -- PALADIN
    { 48827, "PROTECTION" }, -- Avenger's Shield
    { 48825, "HOLY" }, -- Holy Shock
    { 53563, "HOLY" }, -- Beacon of Light
    { 35395, "RETRIBUTION" }, -- Crusader Strike
    { 66006, "RETRIBUTION" }, -- Divine Storm
    { 20066, "RETRIBUTION" }, -- Repentance
    -- ROGUE
    { 48666, "ASSASSINATION" }, -- Mutilate
    { 14177, "ASSASSINATION" }, -- Cold Blood
    { 51690, "COMBAT" }, -- Killing Spree
    { 13877, "COMBAT" }, -- Blade Flurry
    { 13750, "COMBAT" }, -- Adrenaline Rush
    { 36554, "SUBTLETY" }, -- Shadowstep
    { 48660, "SUBTLETY" }, -- Hemorrhage
    { 51713, "SUBTLETY" }, -- Shadow Dance
    -- PRIEST
    { 53007, "DISCIPLINE" }, -- Penance
    { 10060, "DISCIPLINE" }, -- Power Infusion
    { 33206, "DISCIPLINE" }, -- Pain Suppression
    { 34861, "HOLY" }, -- Circle of Healing
    { 15487, "SHADOW" }, -- Silence
    { 48160, "SHADOW" }, -- Vampiric Touch
    -- DEATHKNIGHT
    { 55262, "BLOOD" }, -- Heart Strike
    { 49203, "FROST" }, -- Hungering Cold
    { 55268, "FROST" }, -- Frost Strike
    { 51411, "FROST" }, -- Howling Blast
    { 55271, "UNHOLY" }, -- Scourge Strike
    -- MAGE
    { 44781, "ARCANE" }, -- Arcane Barrage
    { 55360, "FIRE" }, -- Living Bomb
    { 42950, "FIRE" }, -- Dragon's Breath
    { 42945, "FIRE" }, -- Blast Wave
    { 44572, "FROST" }, -- Deep Freeze
    -- WARLOCK
    { 59164, "AFFLICTION" }, -- Haunt
    { 47843, "AFFLICTION" }, -- Unstable Affliction
    { 59672, "DEMONOLOGY" }, -- Metamorphosis
    { 47193, "DEMONOLOGY" }, -- Demonic Empowerment
    { 59172, "DESTRUCTION" }, -- Chaos Bolt
    { 47847, "DESTRUCTION" }, -- Shadowfury
    -- SHAMAN
    { 59159, "ELEMENTAL" }, -- Thunderstorm
    { 16166, "ELEMENTAL" }, -- Elemental Mastery
    { 51533, "ENHANCEMENT" }, -- Feral Spirit
    { 30823, "ENHANCEMENT" }, -- Shamanistic Rage
    { 17364, "ENHANCEMENT" }, -- Stormstrike
    { 61301, "RESTORATION" }, -- Riptide
    { 51886, "RESTORATION" }, -- Cleanse Spirit
    -- HUNTER
    { 19577, "BEAST_MASTERY" }, -- Intimidation
    { 34490, "MARKSMANSHIP" }, -- Silencing Shot
    { 53209, "MARKSMANSHIP" }, -- Chimera Shot
    { 60053, "SURVIVAL" }, -- Explosive Shot
    { 49012, "SURVIVAL" }, -- Wyvern Sting
    -- DRUID
    { 53201, "BALANCE" }, -- Starfall
    { 61384, "BALANCE" }, -- Typhoon
    { 24858, "BALANCE" }, -- Moonkin Form
    { 48566, "FERAL" }, -- Mangle (Cat)
    { 48564, "FERAL" }, -- Mangle (Bear)
    { 18562, "RESTORATION" }, -- Swiftmend
    { 33891, "RESTORATION" }, -- Tree of Life
    { 53251, "RESTORATION" }, -- Wild Growth
}

for _, entry in ipairs(buffs) do
    add(SpecData.specBuffs, entry[1], entry[2])
end
for _, entry in ipairs(spells) do
    add(SpecData.specSpells, entry[1], entry[2])
end
