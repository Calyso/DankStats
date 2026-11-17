--============================================================================
-- DankStats
-- Shows each equipped item's stats next to the slot on the character
-- sheet, with an enchant badge (green "E" / red "E") on each slot icon.
--
-- Works on retail and Classic clients:
--   * C_TooltipInfo when available, hidden GameTooltip otherwise
--   * C_Item / GetItemInfo fallbacks
--
-- Slash commands:
--   /ds            refresh the display
--   /ds debug      print the raw tooltip lines of the ranged slot
--   /ds version    print the current addon version
--============================================================================

local addonName, ns = ...

-- Enchant badges on the slot icons:
--   green "E" -> item is enchanted
--   red   "E" -> slot can be enchanted but isn't
--
-- The badges are a dark chip with the letter "E" as a FontString, so no
-- game texture files are needed and they render on every client and era.

---------------------------------------------------------------------------
-- Slot layout (standard character sheet).
-- enchantable: true = any item, false = never, "SHIELD_ONLY" = shields only
---------------------------------------------------------------------------
local SLOTS = {
    { name = "CharacterHeadSlot",          side = "LEFT",        enchantable = true },
    { name = "CharacterNeckSlot",          side = "LEFT",        enchantable = false },
    { name = "CharacterShoulderSlot",      side = "LEFT",        enchantable = true },
    { name = "CharacterBackSlot",          side = "LEFT",        enchantable = true },
    { name = "CharacterChestSlot",         side = "LEFT",        enchantable = true },
    { name = "CharacterWristSlot",         side = "LEFT",        enchantable = true },

    { name = "CharacterHandsSlot",         side = "RIGHT",       enchantable = true },
    { name = "CharacterWaistSlot",         side = "RIGHT",       enchantable = false },
    { name = "CharacterLegsSlot",          side = "RIGHT",       enchantable = true },
    { name = "CharacterFeetSlot",          side = "RIGHT",       enchantable = true },
    { name = "CharacterFinger0Slot",       side = "RIGHT",       enchantable = false },
    { name = "CharacterFinger1Slot",       side = "RIGHT",       enchantable = false },
    { name = "CharacterTrinket0Slot",      side = "RIGHT",       enchantable = false },
    { name = "CharacterTrinket1Slot",      side = "RIGHT",       enchantable = false },

    { name = "CharacterMainHandSlot",      side = "BOTTOM_LEFT", enchantable = true },
    { name = "CharacterSecondaryHandSlot", side = "BOTTOM",      enchantable = "SHIELD_ONLY" },
    { name = "CharacterRangedSlot",        side = "TOP_RANGED",  enchantable = true },
}

---------------------------------------------------------------------------
-- Stat patterns. Patterns are Lua patterns (unanchored, matched against the
-- lowercased, color-stripped line). First matching entry wins; the first
-- capture group is the value. More specific entries come first.
---------------------------------------------------------------------------
local STAT_PATTERNS = {
    { label = "RAP",   color = "ff9933", patterns = {
        "%+(%d+)%s+ranged attack power",
        "ranged attack power%s+by%s+(%d+)",
    }},
    { label = "AP",    color = "ff9933", patterns = {
        "%+(%d+)%s+attack power",
        "attack power%s+by%s+(%d+)",
    }},
    { label = "Str",   color = "ff4d4d", patterns = {
        "%+(%d+)%s+strength",
    }},
    { label = "Agi",   color = "66ff66", patterns = {
        "%+(%d+)%s+agility",
    }},
    { label = "Int",   color = "66b3ff", patterns = {
        "%+(%d+)%s+intellect",
    }},
    { label = "Spi",   color = "d9b3ff", patterns = {
        "%+(%d+)%s+spirit",
    }},
    { label = "Stam",  color = "ffcc66", patterns = {
        "%+(%d+)%s+stamina",
    }},
    { label = "SCrit", color = "ff3333", patterns = {
        "%+(%d+%.?%d*)%s*%%?%s+spell critical strike",
        "spell critical strike%s+by%s+(%d+%.?%d*)%s*%%?",
    }},
    { label = "Crit",  color = "ff3333", patterns = {
        "%+(%d+%.?%d*)%s*%%?%s+critical strike",
        "critical strike%s+by%s+(%d+%.?%d*)%s*%%?",
    }},
    { label = "SHit",  color = "33ff99", patterns = {
        "%+(%d+%.?%d*)%s*%%?%s+spell hit",
        "hit with spells%s+by%s+(%d+%.?%d*)%s*%%?",
    }},
    { label = "Hit",   color = "33ff99", patterns = {
        "%+(%d+%.?%d*)%s*%%?%s+chance to hit",
        "chance to hit%s+by%s+(%d+%.?%d*)%s*%%?",
    }},
    { label = "Dodge", color = "99ccff", patterns = {
        "%+(%d+%.?%d*)%s*%%?%s+chance to dodge",
        "dodge an attack%s+by%s+(%d+%.?%d*)%s*%%?",
    }},
    { label = "Parry", color = "99ccff", patterns = {
        "%+(%d+%.?%d*)%s*%%?%s+chance to parry",
        "parry an attack%s+by%s+(%d+%.?%d*)%s*%%?",
    }},
    -- "Increases damage and healing done by up to X points" (SP hybrid)
    { label = "SP",    color = "cc66ff", patterns = {
        "damage and healing done by up to%s+(%d+)",
        "healing and damage done by up to%s+(%d+)",
    }},
    -- "Increases healing done by up to X points"
    { label = "Heal",  color = "99ff99", patterns = {
        "healing done by up to%s+(%d+)",
    }},
    { label = "MP5",   color = "33ccff", patterns = {
        "restores%s+(%d+)%s+mana per 5",
    }},
    { label = "Def",   color = "cccccc", patterns = {
        "increased defense%s+%?(%d+)",
    }},
    { label = "SpPow", color = "9999ff", patterns = {
        "%+(%d+)%s+spell power",
    }},
    { label = "Haste", color = "ffcc00", patterns = {
        "%+(%d+)%s+haste rating?",
    }},
}

-- Lines that must never be treated as stat lines or enchant names.
local IGNORE_PATTERNS = {
    "^equip:",
    "^use:",
    "^set:",
    "^%d+pc%:",        -- "2pc:" / "3pc:" set bonus lines
    "%(%d+%s*min%)",   -- cooldown lines, e.g. "(3 min)"
    "%(%d+%s*sec%)",
    "charges%)",       -- e.g. "3 Charges)"
}

---------------------------------------------------------------------------
-- Tooltip scanning
---------------------------------------------------------------------------
local scanTip = CreateFrame("GameTooltip", "DankStatsScanTooltip", nil, "GameTooltipTemplate")
scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")

local function IsGreenColor(r, g, b)
    if not r or not g or not b then return false end
    return r < 0.25 and g > 0.75 and b < 0.25
end

local function CleanText(text)
    text = text:gsub("|c%x+", ""):gsub("|r", "")
    local trimmed = text:match("^%s*(.-)%s*$")
    return trimmed or text
end

-- Returns { { text = "raw line", isGreen = bool }, ... }
local function GetTooltipLines(slotID)
    local lines = {}

    if C_TooltipInfo and C_TooltipInfo.GetInventoryItem then
        local ok, data = pcall(C_TooltipInfo.GetInventoryItem, "player", slotID)
        if ok and data and data.lines then
            for _, line in ipairs(data.lines) do
                local text = line.leftText
                if text and text ~= "" then
                    local c = line.leftColor
                    local isGreen = (c and IsGreenColor(c.r, c.g, c.b))
                        or (text:lower():find("|cff00ff00") ~= nil)
                    table.insert(lines, { text = text, isGreen = isGreen })
                end
            end
        end
        return lines
    end

    scanTip:ClearLines()
    scanTip:SetInventoryItem("player", slotID)
    for i = 1, scanTip:NumLines() do
        local fs = nil
        if scanTip.GetFontString then
            fs = scanTip:GetFontString(i, "LEFT")
        end
        if not fs then
            fs = _G["DankStatsScanTooltipTextLeft" .. i]
        end
        if fs then
            local text = fs:GetText()
            if text and text ~= "" then
                local r, g, b = fs:GetTextColor()
                local isGreen = IsGreenColor(r, g, b)
                    or (text:lower():find("|cff00ff00") ~= nil)
                table.insert(lines, { text = text, isGreen = isGreen })
            end
        end
    end

    return lines
end

---------------------------------------------------------------------------
-- Item helpers
---------------------------------------------------------------------------
local function GetItemNameByID(itemID)
    if C_Item and C_Item.GetItemInfo then
        local ok, name = pcall(C_Item.GetItemInfo, itemID)
        if ok and name and name ~= "" then return name end
    end
    if GetItemInfo then
        local ok, name = pcall(GetItemInfo, itemID)
        if ok and name and name ~= "" then return name end
    end
    return nil
end

local function GetEquipLoc(itemLink)
    if C_Item and C_Item.GetItemInfo then
        local ok, _, _, _, _, _, _, _, equipLoc = pcall(C_Item.GetItemInfo, itemLink)
        if ok and equipLoc then return equipLoc end
    end
    if GetItemInfo then
        local ok, _, _, _, _, _, _, _, equipLoc = pcall(GetItemInfo, itemLink)
        if ok and equipLoc then return equipLoc end
    end
    return nil
end

-- Enchant ID is the second numeric field of an item link: item:ID:ENCHANT:...
local function GetEnchantID(itemLink)
    local id = itemLink:match("item:%d+:(%d+)")
    if id and id ~= "0" then
        return tonumber(id)
    end
    return nil
end

local function CanBeEnchanted(itemLink, enchantRule)
    if not enchantRule then
        return false
    end
    if enchantRule ~= "SHIELD_ONLY" then
        return true
    end
    return GetEquipLoc(itemLink) == "INVTYPE_SHIELD"
end

---------------------------------------------------------------------------
-- Per-slot stat text + enchant state
---------------------------------------------------------------------------
local function IsIgnorableLine(lowerText, enchantName)
    if enchantName then
        local ename = enchantName:lower()
        -- The enchant name itself (with or without an "Enchanted:" prefix)
        if lowerText == ename
            or lowerText:find("enchanted:%s*" .. ename) ~= nil
            or lowerText:find("^enchanted:") ~= nil then
            return true
        end
    end
    for _, pat in ipairs(IGNORE_PATTERNS) do
        if lowerText:match(pat) then
            return true
        end
    end
    return false
end

local function MatchStat(lowerText)
    for _, entry in ipairs(STAT_PATTERNS) do
        for _, pat in ipairs(entry.patterns) do
            local val = lowerText:match(pat)
            if val then
                return string.format("|cff%s+%s %s|r", entry.color, val, entry.label)
            end
        end
    end
    return nil
end

local function GetSlotStatText(slotID, enchantRule)
    local itemLink = GetInventoryItemLink("player", slotID)
    if not itemLink then
        return "", "NONE"
    end

    local enchantID = GetEnchantID(itemLink)
    local enchantName = enchantID and GetItemNameByID(enchantID) or nil

    local parts = {}
    for _, lineData in ipairs(GetTooltipLines(slotID)) do
        local clean = CleanText(lineData.text)
        if clean ~= "" and not IsIgnorableLine(clean:lower(), enchantName) then
            local chip = MatchStat(clean:lower())
            if chip then
                table.insert(parts, chip)
            end
        end
    end

    -- Enchant state, shown as a badge on the slot icon:
    --   "ENCHANTED"     -> green "E"
    --   "NEEDS_ENCHANT" -> red "E"
    --   "NONE"          -> no icon (empty slot or non-enchantable item)
    local state = "NONE"
    if enchantID then
        state = "ENCHANTED"
    elseif CanBeEnchanted(itemLink, enchantRule) then
        state = "NEEDS_ENCHANT"
    end

    return table.concat(parts, "\n"), state
end

---------------------------------------------------------------------------
-- Slot labels on the character sheet
---------------------------------------------------------------------------
local slotLabels = {}

local function CreateSlotLabels()
    for _, slotInfo in ipairs(SLOTS) do
        local slotFrame = _G[slotInfo.name]
        if slotFrame and not slotLabels[slotInfo.name] then
            local text = slotFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            text:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
            text:SetSpacing(2)
            text:SetShadowColor(0, 0, 0, 1)
            text:SetShadowOffset(1, -1)

            if slotInfo.side == "LEFT" then
                text:SetPoint("LEFT", slotFrame, "RIGHT", 6, 0)
                text:SetJustifyH("LEFT")
            elseif slotInfo.side == "RIGHT" or slotInfo.side == "BOTTOM_LEFT" then
                text:SetPoint("RIGHT", slotFrame, "LEFT", -6, 0)
                text:SetJustifyH("RIGHT")
            elseif slotInfo.side == "BOTTOM" then
                text:SetPoint("TOP", slotFrame, "BOTTOM", 0, -4)
                text:SetJustifyH("CENTER")
            elseif slotInfo.side == "TOP_RANGED" then
                -- Anchor above the ranged slot so it never covers the ammo slot
                text:SetPoint("BOTTOM", slotFrame, "TOP", 0, 4)
                text:SetJustifyH("CENTER")
            end

            -- Enchant badge on the item icon's bottom-right corner:
            -- a dark chip with a green "E" (enchanted) or red "E" (needs enchant)
            local slotWidth = slotFrame:GetWidth()
            local S = (slotWidth and slotWidth > 0 and slotWidth * 0.55) or 18
            local badge = CreateFrame("Frame", nil, slotFrame)
            badge:SetSize(S, S)
            badge:SetPoint("BOTTOMRIGHT", slotFrame, "BOTTOMRIGHT", 1, 1)
            badge:Hide()

            local bg = badge:CreateTexture(nil, "OVERLAY")
            bg:SetAllPoints(badge)
            bg:SetColorTexture(0, 0, 0)
            bg:SetVertexColor(1, 1, 1, 0.55)

            local letterSize = math.max(10, math.floor(S * 0.7))
            local badgeLetter = badge:CreateFontString(nil, "OVERLAY")
            badgeLetter:SetFont(STANDARD_TEXT_FONT, letterSize, "OUTLINE")
            badgeLetter:SetPoint("CENTER", badge, "CENTER", 0, -1)
            badgeLetter:SetText("E")

            slotLabels[slotInfo.name] = {
                fontString  = text,
                badge       = badge,
                badgeLetter = badgeLetter,
                slotID      = slotFrame:GetID(),
                enchantable = slotInfo.enchantable,
            }
        end
    end
end

---------------------------------------------------------------------------
-- Ranged slot (slot 18) is class-dependent.
--
-- On classic/Forever-style clients druids and shamans do NOT put a bow,
-- crossbow, or gun in this slot:
--   * Druids  -> a Relic
--   * Shamans -> a Totem
-- Relics and totems cannot be enchanted, so we must never flag those slots
-- as "needs an enchant" (that would show a bogus red "E"). For every other
-- class the slot holds a ranged weapon (bow / crossbow / gun) that CAN be
-- enchanted, so the badge behaves exactly as before for them.
---------------------------------------------------------------------------
local function IsDruidOrShaman()
    local class
    if UnitClass then
        -- UnitClass returns: localizedName, englishName, classID
        class = select(2, UnitClass("player"))
    end
    if not class and UnitClassBase then
        class = select(2, UnitClassBase("player"))
    end
    if not class then
        return false
    end
    class = class:upper()
    return class == "DRUID" or class == "SHAMAN"
end

-- Returns the effective "enchantable" rule for a given slot name.
local function EffectiveEnchantable(slotName, baseRule)
    if slotName == "CharacterRangedSlot" and IsDruidOrShaman() then
        return false
    end
    return baseRule
end

local function UpdateAllStats()
    if not CharacterFrame or not CharacterFrame:IsShown() then
        return false
    end

    CreateSlotLabels()

    for name, data in pairs(slotLabels) do
        local text, state = GetSlotStatText(data.slotID, EffectiveEnchantable(name, data.enchantable))
        data.fontString:SetText(text)

        if data.badge then
            if state == "ENCHANTED" or state == "NEEDS_ENCHANT" then
                data.badge:Show()
                if state == "ENCHANTED" then
                    data.badgeLetter:SetTextColor(0.16, 0.85, 0.22)  -- green "E"
                else
                    data.badgeLetter:SetTextColor(0.85, 0.14, 0.10)  -- red "E"
                end
            else
                data.badge:Hide()
            end
        end
    end

    return true
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

eventFrame:SetScript("OnEvent", function()
    C_Timer.After(0.2, UpdateAllStats)
end)

if CharacterFrame and CharacterFrame.HookScript then
    CharacterFrame:HookScript("OnShow", function()
        C_Timer.After(0.1, UpdateAllStats)
    end)
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local ADDON_VERSION = "1.0.1"

SLASH_DANKSTATS1 = "/ds"
SlashCmdList["DANKSTATS"] = function(msg)
    if msg == "version" then
        print("|cff33ff99DankStats |r version " .. ADDON_VERSION)
        return
    end

    if msg == "debug" then
        print("|cff33ff99DankStats Ranged Tooltip Lines:|r")
        for i, lineData in ipairs(GetTooltipLines(18)) do
            print(i .. " (green=" .. tostring(lineData.isGreen) .. "): " .. lineData.text)
        end
        return
    end

    if UpdateAllStats() then
        print("|cff33ff99DankStats:|r Refreshed character sheet stats.")
    else
        print("|cff33ff99DankStats:|r Open the character sheet to see stats.")
    end
end
