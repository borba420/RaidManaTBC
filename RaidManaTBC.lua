local ADDON_NAME = ...
local DB_NAME = "RaidManaTBCDB"

local MAX_LINES = 40
local UPDATE_INTERVAL = 0.2
local ENABLE_BACKGROUND = true -- Set to false if you want no background panel.
local COMM_PREFIX = "RMTBC1"
local COMM_INTERVAL = 15
local COMM_STALE = 60
local ALERT_COOLDOWN = 45
local DROP_MARKER_THRESHOLD = 8
local DROP_MARKER_DURATION = 3
local INNERVATE_SPELL_ID = 29166
local INNERVATE_COOLDOWN_SECONDS = 600
local DRUID_NONCAST_FORM_SPELL_IDS = {
  1066, -- Aquatic Form
  768, -- Cat Form
  5487, -- Bear Form
  9634, -- Dire Bear Form
  24858, -- Moonkin Form
  783, -- Travel Form
}
local DRUID_MANA_HIDDEN_FORM_SPELL_IDS = {
  768, -- Cat Form
  5487, -- Bear Form
  9634, -- Dire Bear Form
}

local HEALER_CLASSES = {
  PRIEST = true,
  DRUID = true,
  PALADIN = true,
  SHAMAN = true,
}

local MANA_CLASSES = {
  DRUID = true,
  HUNTER = true,
  MAGE = true,
  PALADIN = true,
  PRIEST = true,
  SHAMAN = true,
  WARLOCK = true,
}

local DEFAULTS = {
  visible = true,
  locked = false,
  scale = 1.0,
  point = "CENTER",
  x = 0,
  y = 0,
  view = "all",
  mode = "weighted",
  sort = "low",
  showOffline = false,
  minimapAngle = 225,
  minimap = {
    hide = false,
    minimapPos = 225,
  },
  roleOverrides = {},
  autoGroupVisibility = true,
  readability = "normal", -- normal | readable
  healerAlerts = true,
  alertSenderMode = "leader", -- leader | auto
  innervateCooldowns = {},
  showInnervateMarkers = true,
}

local LATEST_CHANGELOG = {
  "v1.0.11",
  "- Fixed innervate caster selection so dead/disconnected druids are never used or suggested.",
  "- Improved deterministic innervate candidate rules: self is excluded, shapeshifted druids ignored, readiness required.",
  "v1.0.10",
  "- Shapeshifted druids are now hidden only for mana-hiding forms; Moonkin is visible.",
  "- Added group-aware druid filtering: caster suggestions ignore non-casting forms.",
  "- Added compact druid-only Innervate status markers on each row (icon + state: active/ready/CD).",
  "- Added option to toggle innervate markers in the options UI.",
  "- Dead players now remain listed as gray \"DEAD\" entries and are pushed to the bottom.",
  "- Prevented self-request: when a druid is at critical, it requests another eligible druid if available.",
  "v1.0.9",
  "- Critical-only Innervate chat is now deterministic: only <10%% messages and picks a ready druid by name.",
  "- Skips Innervate requests when no in-group druid is currently ready (respecting 10-minute cooldown tracking).",
  "- Critical requests now include suggested caster name: '... Innervate now <Druid>'.",
  "v1.0.8",
  "- Reduced chat clutter: healer alerts now only at <25% and <10%.",
  "- Added realtime blue marker for active Innervate buff.",
  "- Fast-drop marker now uses tighter threshold and shorter duration.",
}

local db
local dirty = true
local elapsedSinceUpdate = 0

local mainFrame
local headerText
local linePool = {}

local entries = {}
local units = {}

local optionsFrame
local optionsButtons = {}
local roleFrame
local roleRows = {}
local ldbObject
local libDBIcon
local previousPctByName = {}
local recentDropUntilByName = {}
local healerAlertStageByName = {}
local healerAlertLastSentByKey = {}
local innervateStateByDruid = {}
local addonPeersByName = {}
local commElapsed = 0
local INNERVATE_NAME = (GetSpellInfo and GetSpellInfo(INNERVATE_SPELL_ID)) or "Innervate"
local INNERVATE_ICON = (GetSpellInfo and select(3, GetSpellInfo(INNERVATE_SPELL_ID))) or "Interface\\Icons\\Spell_Nature_Lightning"
local DRUID_NONCAST_FORM_NAMES = {}
local DRUID_MANA_HIDDEN_FORM_NAMES = {}
for _, spellId in ipairs(DRUID_NONCAST_FORM_SPELL_IDS) do
  local name = GetSpellInfo and GetSpellInfo(spellId)
  if name then
    DRUID_NONCAST_FORM_NAMES[name] = true
  end
end
for _, spellId in ipairs(DRUID_MANA_HIDDEN_FORM_SPELL_IDS) do
  local name = GetSpellInfo and GetSpellInfo(spellId)
  if name then
    DRUID_MANA_HIDDEN_FORM_NAMES[name] = true
  end
end

local function Msg(text)
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99RaidManaTBC|r: " .. text)
end

local function CopyDefaults(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then
        dst[k] = {}
      end
      CopyDefaults(dst[k], v)
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
end

local function ColorizeName(name, classFile)
  local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
  if c then
    return string.format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, name)
  end
  return name
end

local function ColorizePercent(pct)
  local color
  if pct >= 70 then
    color = "ff33ff33"
  elseif pct >= 40 then
    color = "ffffff33"
  else
    color = "ffff3333"
  end
  return string.format("|c%s%.1f%%|r", color, pct)
end

local function HasInnervate(unit)
  if not UnitBuff then
    return false
  end
  for i = 1, 40 do
    local name = UnitBuff(unit, i)
    if not name then
      break
    end
    if name == INNERVATE_NAME then
      return true
    end
  end
  return false
end

local function IsDruidInShapeshiftForm(unit, formNames)
  if not UnitBuff or not UnitClass then
    return false
  end

  local _, classFile = UnitClass(unit)
  if classFile ~= "DRUID" then
    return false
  end

  local check = formNames or DRUID_NONCAST_FORM_NAMES

  for i = 1, 40 do
    local buffName = UnitBuff(unit, i)
    if not buffName then
      break
    end
    if check[buffName] then
      return true
    end
  end

  return false
end

local function SyncMinimapSettings()
  if type(db.minimap) ~= "table" then
    db.minimap = {}
  end

  if type(db.minimap.minimapPos) ~= "number" then
    db.minimap.minimapPos = tonumber(db.minimapAngle) or 225
  end

  if db.minimap.minimapPos < 0 then
    db.minimap.minimapPos = db.minimap.minimapPos + 360
  end

  if db.minimap.minimapPos >= 360 then
    db.minimap.minimapPos = db.minimap.minimapPos % 360
  end

  db.minimapAngle = db.minimap.minimapPos

  if db.minimap.hide == nil then
    db.minimap.hide = false
  end
end

local function SaveFramePosition()
  local point, _, _, x, y = mainFrame:GetPoint(1)
  db.point = point or "CENTER"
  db.x = math.floor((x or 0) + 0.5)
  db.y = math.floor((y or 0) + 0.5)
end

local function ApplyFramePosition()
  mainFrame:ClearAllPoints()
  mainFrame:SetPoint(db.point or "CENTER", UIParent, db.point or "CENTER", db.x or 0, db.y or 0)
end

local function ApplyFrameSettings()
  mainFrame:SetScale(1.0)
  ApplyFramePosition()

  if db.locked then
    mainFrame:EnableMouse(false)
  else
    mainFrame:EnableMouse(true)
  end

  if db.visible then
    mainFrame:Show()
  else
    mainFrame:Hide()
  end
end

local function RefreshMinimapButton()
  if not libDBIcon then
    return
  end

  SyncMinimapSettings()
  libDBIcon:Refresh(ADDON_NAME, db.minimap)

  local button = libDBIcon:GetMinimapButton(ADDON_NAME)
  if button and not button.__RaidManaTBCHooked then
    button:HookScript("OnDragStop", function()
      db.minimapAngle = tonumber(db.minimap and db.minimap.minimapPos) or db.minimapAngle
    end)
    button.__RaidManaTBCHooked = true
  end
end

local function IsHealerClass(classFile)
  return HEALER_CLASSES[classFile] == true
end

local function IsManaClass(classFile)
  return MANA_CLASSES[classFile] == true
end

local function NormalizeName(name)
  if not name or name == "" then
    return nil
  end
  local shortName = name:match("^([^%-]+)") or name
  return string.lower(shortName)
end

local function GetOverrideRoleByName(name)
  if type(db.roleOverrides) ~= "table" then
    db.roleOverrides = {}
  end
  local key = NormalizeName(name)
  if not key then
    return nil
  end
  return db.roleOverrides[key]
end

local function IsHealerUnit(unit, classFile, name)
  local overridden = GetOverrideRoleByName(name)
  if overridden == "HEALER" then
    return true
  end
  if overridden == "TANK" or overridden == "DAMAGER" then
    return false
  end

  if UnitGroupRolesAssigned then
    local role = UnitGroupRolesAssigned(unit)
    if role == "HEALER" then
      return true
    end
    if role == "TANK" or role == "DAMAGER" then
      return false
    end
  end
  return IsHealerClass(classFile)
end

local function GetRoleIcon(role)
  if role == "TANK" then
    return "|TInterface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES:12:12:0:0:64:64:0:19:22:41|t"
  end
  if role == "HEALER" then
    return "|TInterface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES:12:12:0:0:64:64:20:39:1:20|t"
  end
  if role == "DAMAGER" then
    return "|TInterface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES:12:12:0:0:64:64:20:39:22:41|t"
  end
  return ""
end

local function IsValidRole(role)
  return role == "TANK" or role == "HEALER" or role == "DAMAGER"
end

local function GetFallbackRoleForClass(classFile)
  if HEALER_CLASSES[classFile] then
    return "HEALER"
  end
  return "DAMAGER"
end

local function GetReadabilitySettings()
  if db.readability == "readable" then
    return "GameFontHighlightSmall", 14
  end
  return "GameFontHighlightSmall", 13
end

local function IsInGroupNow()
  if UnitExists("raid1") then
    return true
  end
  for i = 1, 4 do
    if UnitExists("party" .. i) then
      return true
    end
  end
  return false
end

local function GetPlayerKey()
  return NormalizeName(UnitName("player"))
end

local function GetGroupChannel()
  if UnitInRaid and UnitInRaid("player") then
    return "RAID"
  end
  if IsInGroupNow() then
    return "PARTY"
  end
  return nil
end

local function SendAddonPing()
  local channel = GetGroupChannel()
  if not channel then
    return
  end
  if C_ChatInfo and C_ChatInfo.SendAddonMessage then
    C_ChatInfo.SendAddonMessage(COMM_PREFIX, "PING", channel)
  elseif SendAddonMessage then
    SendAddonMessage(COMM_PREFIX, "PING", channel)
  end
end

local function RegisterAddonPrefix()
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(COMM_PREFIX)
  elseif RegisterAddonMessagePrefix then
    RegisterAddonMessagePrefix(COMM_PREFIX)
  end
end

local AddGroupUnits

local function BuildGroupMemberKeySet()
  local set = {}
  AddGroupUnits()
  for i = 1, #units do
    local unit = units[i]
    if UnitExists(unit) then
      local name = UnitName(unit)
      local key = NormalizeName(name)
      if key then
        set[key] = true
      end
    end
  end
  return set
end

local function GetGroupLeaderKey()
  AddGroupUnits()
  for i = 1, #units do
    local unit = units[i]
    if UnitExists(unit) and UnitIsGroupLeader and UnitIsGroupLeader(unit) then
      return NormalizeName(UnitName(unit))
    end
  end
  return nil
end

local function CanManageOverrides()
  if not IsInGroupNow() then
    return true
  end
  if UnitIsGroupLeader then
    return UnitIsGroupLeader("player")
  end
  if IsRaidLeader and IsRaidLeader() then
    return true
  end
  if IsPartyLeader and IsPartyLeader() then
    return true
  end
  return false
end

local function PruneAddonPeers(groupSet, now)
  for nameKey, lastSeen in pairs(addonPeersByName) do
    if (not groupSet[nameKey]) or (now - lastSeen > COMM_STALE) then
      addonPeersByName[nameKey] = nil
    end
  end
end

local function SendAddonMessageSafe(msg)
  local channel = GetGroupChannel()
  if not channel then
    return
  end
  if C_ChatInfo and C_ChatInfo.SendAddonMessage then
    C_ChatInfo.SendAddonMessage(COMM_PREFIX, msg, channel)
  elseif SendAddonMessage then
    SendAddonMessage(COMM_PREFIX, msg, channel)
  end
end

local function SerializeOverrides()
  if type(db.roleOverrides) ~= "table" then
    db.roleOverrides = {}
  end
  local keys = {}
  for key in pairs(db.roleOverrides) do
    keys[#keys + 1] = key
  end
  table.sort(keys)

  local parts = {}
  for i = 1, #keys do
    local k = keys[i]
    local v = db.roleOverrides[k]
    if IsValidRole(v) then
      parts[#parts + 1] = k .. "=" .. v
    end
  end
  return table.concat(parts, ";")
end

local function ApplySerializedOverrides(payload)
  if type(db.roleOverrides) ~= "table" then
    db.roleOverrides = {}
  end
  wipe(db.roleOverrides)

  if payload and payload ~= "" then
    for pair in string.gmatch(payload, "([^;]+)") do
      local key, role = pair:match("^([^=]+)=([^=]+)$")
      if key and IsValidRole(role) then
        db.roleOverrides[key] = role
      end
    end
  end

  dirty = true
end

local function BroadcastOverrideFullSync()
  if not IsInGroupNow() or not CanManageOverrides() then
    return
  end
  SendAddonMessageSafe("OVR_FULL:" .. SerializeOverrides())
end

local function BroadcastOverrideSet(key, role)
  if not IsInGroupNow() or not CanManageOverrides() then
    return
  end
  if key and IsValidRole(role) then
    SendAddonMessageSafe("OVR_SET:" .. key .. ":" .. role)
  end
end

local function BroadcastOverrideDelete(key)
  if not IsInGroupNow() or not CanManageOverrides() then
    return
  end
  if key then
    SendAddonMessageSafe("OVR_DEL:" .. key)
  end
end

local function BroadcastOverrideClear()
  if not IsInGroupNow() or not CanManageOverrides() then
    return
  end
  SendAddonMessageSafe("OVR_CLR")
end

local function ApplyAutoGroupVisibility()
  if not db.autoGroupVisibility then
    return
  end
  db.visible = IsInGroupNow()
end

local function GetTriagePrefix(entry)
  if entry.isDead then
    return ""
  end

  local now = GetTime and GetTime() or 0
  local parts = {}

  if entry.pct < 20 then
    parts[#parts + 1] = "|cffff5555!!|r"
  end
  local untilTime = recentDropUntilByName[NormalizeName(entry.name) or ""] or 0
  if untilTime > now then
    parts[#parts + 1] = "|cffffaa33v|r"
  end

  if #parts > 0 then
    return table.concat(parts, "") .. " "
  end
  return ""
end

local function IsPlayerGroupLeader()
  if UnitIsGroupLeader then
    return UnitIsGroupLeader("player")
  end
  if IsRaidLeader and IsRaidLeader() then
    return true
  end
  if IsPartyLeader and IsPartyLeader() then
    return true
  end
  return false
end

local function GetInnervateStatusText(unit, name, now)
  if not unit or not name then
    return ""
  end

  if not HasInnervate(unit) then
    local key = NormalizeName(name)
    local state = key and innervateStateByDruid[key]
    if state then
      if state.readyAt > 0 and state.readyAt > now then
        return string.format("|T%s:10:10:0:0:64:64|t|cffffaa00CD|r", INNERVATE_ICON)
      end
      return string.format("|T%s:10:10:0:0:64:64|t|cff66ff66RDY|r", INNERVATE_ICON)
    end
    return ""
  end

  return string.format("|T%s:12:12:0:0:64:64|t", INNERVATE_ICON)
end

local function RefreshGroupDruids()
  wipe(innervateStateByDruid)
  if type(db.innervateCooldowns) ~= "table" then
    db.innervateCooldowns = {}
  end

  AddGroupUnits()
  local now = GetTime and GetTime() or 0
  for i = 1, #units do
    local unit = units[i]
    if UnitExists(unit) then
      local _, classFile = UnitClass(unit)
      if classFile == "DRUID" then
        local name = UnitName(unit) or unit
        local key = NormalizeName(name)
        if key then
          local readyAt = tonumber(db.innervateCooldowns[key]) or 0
          if readyAt < now then
            readyAt = 0
          end
          innervateStateByDruid[key] = {
            name = name,
            readyAt = readyAt,
            key = key,
            isDead = UnitIsDeadOrGhost and UnitIsDeadOrGhost(unit),
            connected = UnitIsConnected and UnitIsConnected(unit),
            inShapeshift = IsDruidInShapeshiftForm(unit),
          }
        end
      end
    end
  end
end

local function IsUsableInnervateCaster(data, selfKey, now)
  return data ~= nil
    and data.key ~= selfKey
    and (not data.inShapeshift)
    and (not data.isDead)
    and data.connected ~= false
    and data.readyAt <= now
end

local function GetReadyInnervateCaster()
  -- Always rebuild from the current group before selecting a caster
  -- so stale names from a previous group are never reused.
  RefreshGroupDruids()

  local now = GetTime and GetTime() or 0
  local selfKey = GetPlayerKey()

  local ready = {}
  for _, data in pairs(innervateStateByDruid) do
    if IsUsableInnervateCaster(data, selfKey, now) then
      ready[#ready + 1] = data.name
    end
  end

  if #ready == 0 then
    return nil
  end

  table.sort(ready)
  return ready[1]
end

local function GroupHasUsableDruid()
  -- Keep this in sync with current group state.
  RefreshGroupDruids()
  local selfKey = GetPlayerKey()
  for _, data in pairs(innervateStateByDruid) do
    if IsUsableInnervateCaster(data, selfKey, GetTime and GetTime() or 0) then
      return true
    end
  end
  return false
end

local function RecordInnervateCast(sourceName)
  if not sourceName then
    return
  end

  local sourceKey = NormalizeName(sourceName)
  if not sourceKey then
    return
  end

  if type(db.innervateCooldowns) ~= "table" then
    db.innervateCooldowns = {}
  end
  db.innervateCooldowns[sourceKey] = (GetTime and GetTime() or 0) + INNERVATE_COOLDOWN_SECONDS

  if not innervateStateByDruid[sourceKey] then
    RefreshGroupDruids()
  end
  if innervateStateByDruid[sourceKey] then
    innervateStateByDruid[sourceKey].readyAt = db.innervateCooldowns[sourceKey]
  else
    innervateStateByDruid[sourceKey] = { key = sourceKey, name = sourceName, readyAt = db.innervateCooldowns[sourceKey] }
  end
end

local function GetAlertChatChannel()
  return GetGroupChannel()
end

local function IsAlertSender()
  if db.alertSenderMode ~= "auto" then
    return IsPlayerGroupLeader()
  end

  local playerKey = GetPlayerKey()
  if not playerKey then
    return false
  end

  local now = GetTime and GetTime() or 0
  local groupSet = BuildGroupMemberKeySet()
  PruneAddonPeers(groupSet, now)
  addonPeersByName[playerKey] = now

  local leaderKey = GetGroupLeaderKey()
  if leaderKey and addonPeersByName[leaderKey] then
    return playerKey == leaderKey
  end

  local chosen
  for nameKey, _ in pairs(addonPeersByName) do
    if groupSet[nameKey] then
      if not chosen or nameKey < chosen then
        chosen = nameKey
      end
    end
  end

  return chosen == playerKey
end

local function GetHealerAlertStage(pct, previousStage)
  if pct < 10 then
    return 3
  end
  if pct < 25 then
    return 2
  end

  -- Hysteresis reset: don't clear stage until healer is clearly above threshold.
  if previousStage == 3 and pct < 15 then
    return 3
  end
  if previousStage and previousStage >= 2 and pct < 30 then
    return 2
  end
  if previousStage and previousStage >= 1 and pct < 55 then
    return 1
  end
  return 0
end

local function SendHealerManaAlert(name, nameKey, pct, stage)
  if not db.healerAlerts then
    return
  end

  local now = GetTime and GetTime() or 0
  local cooldownKey = (nameKey or name) .. ":" .. tostring(stage)
  local lastSent = healerAlertLastSentByKey[cooldownKey] or 0
  if (now - lastSent) < ALERT_COOLDOWN then
    return
  end

  if not IsAlertSender() then
    return
  end

  local channel = GetAlertChatChannel()
  if not channel then
    return
  end

  local msg
  if stage == 3 then
    local hasDruid = GroupHasUsableDruid()
    if hasDruid then
      local caster = GetReadyInnervateCaster()
      if caster then
        msg = string.format("%s mana CRITICAL (%.1f%%) - Innervate now %s", name, pct, caster)
      else
        msg = string.format("%s mana CRITICAL (%.1f%%).", name, pct)
      end
    else
      msg = string.format("%s mana CRITICAL (%.1f%%).", name, pct)
    end
  elseif stage == 2 then
    msg = string.format("%s mana LOW (%.1f%%).", name, pct)
  else
    return
  end

  SendChatMessage(msg, channel)
  healerAlertLastSentByKey[cooldownKey] = now
end

local function HandleCombatLogEvent()
  if not CombatLogGetCurrentEventInfo then
    return
  end

  local args = { CombatLogGetCurrentEventInfo() }
  local subEvent = args[2]
  if subEvent ~= "SPELL_CAST_SUCCESS" and subEvent ~= "SPELL_AURA_APPLIED" and subEvent ~= "SPELL_AURA_REFRESH" then
    return
  end

  local spellId = args[12]
  if spellId ~= INNERVATE_SPELL_ID then
    return
  end

  local sourceName = args[5]
  if not sourceName then
    return
  end

  RefreshGroupDruids()
  local sourceKey = NormalizeName(sourceName)
  if sourceKey and innervateStateByDruid[sourceKey] then
    RecordInnervateCast(sourceName)
  end
end

AddGroupUnits = function()
  wipe(units)

  if UnitExists("raid1") then
    for i = 1, 40 do
      local unit = "raid" .. i
      if UnitExists(unit) then
        units[#units + 1] = unit
      end
    end
  elseif UnitExists("party1") or UnitExists("party2") or UnitExists("party3") or UnitExists("party4") then
    units[#units + 1] = "player"
    for i = 1, 4 do
      local unit = "party" .. i
      if UnitExists(unit) then
        units[#units + 1] = unit
      end
    end
  else
    units[#units + 1] = "player"
  end
end

local function BuildEntries()
  wipe(entries)

  local totalCurrent = 0
  local totalMax = 0
  local totalPct = 0
  local count = 0
  local now = GetTime and GetTime() or 0

  RefreshGroupDruids()

  for i = 1, #units do
    local unit = units[i]
    if UnitExists(unit) then
      local connected = UnitIsConnected(unit)
      if connected or db.showOffline then
        local _, classFile = UnitClass(unit)
        if classFile == "DRUID" and IsDruidInShapeshiftForm(unit, DRUID_MANA_HIDDEN_FORM_NAMES) then
          -- Skip shapeshifted druids from the UI list.
        else
          local name = UnitName(unit) or unit
          if db.view ~= "healers" or IsHealerUnit(unit, classFile, name) then
          local maxMana = UnitPowerMax(unit, 0) or 0
          if IsManaClass(classFile) and maxMana > 0 then
            local currentMana = connected and (UnitPower(unit, 0) or 0) or 0
            local pct = (currentMana / maxMana) * 100
            local role = UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit) or "NONE"
            local overriddenRole = GetOverrideRoleByName(name)
            local nameKey = NormalizeName(name) or name
            local isDead = UnitIsDeadOrGhost and UnitIsDeadOrGhost(unit)
            if overriddenRole then
              role = overriddenRole
            end
            if not IsValidRole(role) then
              role = GetFallbackRoleForClass(classFile)
            end

              if connected and IsHealerUnit(unit, classFile, name) then
                local oldStage = healerAlertStageByName[nameKey] or 0
                local isDead = UnitIsDeadOrGhost and UnitIsDeadOrGhost(unit)

                if isDead then
                  healerAlertStageByName[nameKey] = 0
                else
                  local stage = GetHealerAlertStage(pct, oldStage)

                  if stage > oldStage and (stage == 2 or stage == 3) then
                    SendHealerManaAlert(name, nameKey, pct, stage)
                  end

                  healerAlertStageByName[nameKey] = stage
                end
              end

              local prev = previousPctByName[nameKey]
              if prev and (prev - pct) >= DROP_MARKER_THRESHOLD then
                local now = GetTime and GetTime() or 0
                recentDropUntilByName[nameKey] = now + DROP_MARKER_DURATION
              end
              previousPctByName[nameKey] = pct

              count = count + 1
              totalCurrent = totalCurrent + currentMana
              totalMax = totalMax + maxMana
              totalPct = totalPct + pct

              entries[#entries + 1] = {
                name = name,
                classFile = classFile,
                pct = pct,
                role = role,
                innervate = HasInnervate(unit),
                innervateStatus = classFile == "DRUID" and GetInnervateStatusText(unit, name, now) or "",
                isDead = isDead,
                index = #entries + 1,
              }
            end
          end
        end
      end
    end
  end

  table.sort(entries, function(a, b)
    if a.isDead ~= b.isDead then
      return not a.isDead
    end
    if a.pct == b.pct then
      if a.name == b.name then
        return a.index < b.index
      end
      return a.name < b.name
    end
    if db.sort == "high" then
      return a.pct > b.pct
    end
    return a.pct < b.pct
  end)

  local avg = 0
  if db.mode == "mean" then
    if count > 0 then
      avg = totalPct / count
    end
  else
    if totalMax > 0 then
      avg = (totalCurrent / totalMax) * 100
    end
  end

  return avg, count
end

local function Render()
  local avg = BuildEntries()
  local viewLabel = (db.view == "healers") and "Healers" or "All"
  headerText:SetText(string.format("Average Mana (%s): %.1f%%", viewLabel, avg))

  local fontObject, lineSpacing = GetReadabilitySettings()
  local shown = math.min(#entries, MAX_LINES)
  for i = 1, shown do
    local e = entries[i]
    local nameColored = ColorizeName(e.name, e.classFile)
    if e.isDead then
      nameColored = "|cff999999" .. e.name .. "|r"
    end
    local prefix = GetTriagePrefix(e)
    local markerSuffix = ""
    if db.view == "all" then
      local roleIcon = GetRoleIcon(e.role)
      if roleIcon ~= "" then
        prefix = prefix .. roleIcon .. " "
      end
    end

    if db.showInnervateMarkers then
      if e.innervate then
        markerSuffix = markerSuffix .. string.format("|T%s:14:14:0:0:64:64|t ", INNERVATE_ICON)
      end
      if e.classFile == "DRUID" and e.innervateStatus ~= "" then
        markerSuffix = markerSuffix .. e.innervateStatus .. " "
      end
    end

    if markerSuffix ~= "" then
      markerSuffix = " " .. markerSuffix
    end

    local pctColored = ColorizePercent(e.pct)
    if e.isDead then
      pctColored = "|cff777777DEAD|r"
      markerSuffix = ""
    end
    linePool[i]:SetFontObject(fontObject)
    linePool[i]:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 6, -6 - (i * lineSpacing))
    linePool[i]:SetText(string.format("%s%s%s: %s", prefix, nameColored, markerSuffix, pctColored))
    linePool[i]:Show()
  end

  for i = shown + 1, MAX_LINES do
    linePool[i]:Hide()
  end

  local height = 10 + 14 + (shown * lineSpacing) + 8
  if height < 32 then height = 32 end
  mainFrame:SetHeight(height)
end

local function MarkDirty()
  dirty = true
end

local function SafeRegister(frame, eventName)
  pcall(frame.RegisterEvent, frame, eventName)
end

local function PrintHelp()
  Msg("Commands:")
  Msg("/raidmana show | hide")
  Msg("/raidmana lock | unlock")
  Msg("/raidmana reset")
  Msg("/raidmana view all | healers")
  Msg("/raidmana mode weighted | mean")
  Msg("/raidmana sort low | high")
  Msg("/raidmana offline on | off")
  Msg("/raidmana alerts on | off")
  Msg("/raidmana innervate on | off")
  Msg("/raidmana sender leader | auto")
  Msg("/raidmana autogroup on | off")
  Msg("/raidmana readability normal | readable")
  Msg("/raidmana set <name> healer|tank|dps")
  Msg("/raidmana remove <name>")
  Msg("/raidmana list | clear")
  Msg("/raidmana options")
  Msg("/raidmana changelog")
end

local function PrintChangelog()
  Msg("Latest changes:")
  for i = 1, #LATEST_CHANGELOG do
    Msg(LATEST_CHANGELOG[i])
  end
end

local function ResetPosition()
  db.point = "CENTER"
  db.x = 0
  db.y = 0
  db.minimapAngle = 225
  if type(db.minimap) ~= "table" then
    db.minimap = {}
  end
  db.minimap.minimapPos = 225
  ApplyFramePosition()
  RefreshMinimapButton()
  MarkDirty()
  Msg("Position reset.")
end

local function RefreshOptionsUI()
  if not optionsFrame then
    return
  end

  if optionsButtons.view then
    optionsButtons.view:SetText("View: " .. (db.view == "healers" and "Healers" or "All"))
  end
  if optionsButtons.mode then
    optionsButtons.mode:SetText("Mode: " .. (db.mode == "mean" and "Mean" or "Weighted"))
  end
  if optionsButtons.sort then
    optionsButtons.sort:SetText("Sort: " .. (db.sort == "high" and "High" or "Low"))
  end
  if optionsButtons.offline then
    optionsButtons.offline:SetText("Offline: " .. (db.showOffline and "On" or "Off"))
  end
  if optionsButtons.alerts then
    optionsButtons.alerts:SetText("Healer Alerts: " .. (db.healerAlerts and "On" or "Off"))
  end
  if optionsButtons.innervateMarkers then
    optionsButtons.innervateMarkers:SetText("Innervate Markers: " .. (db.showInnervateMarkers and "On" or "Off"))
  end
  if optionsButtons.sender then
    optionsButtons.sender:SetText("Alert Sender: " .. (db.alertSenderMode == "auto" and "Auto" or "Leader"))
  end
  if optionsButtons.autogroup then
    optionsButtons.autogroup:SetText("Auto Group: " .. (db.autoGroupVisibility and "On" or "Off"))
  end
  if optionsButtons.readability then
    optionsButtons.readability:SetText("Readability: " .. (db.readability == "readable" and "Readable" or "Normal"))
  end
  if optionsButtons.lock then
    optionsButtons.lock:SetText(db.locked and "Unlock Frame" or "Lock Frame")
  end
  if optionsButtons.visible then
    optionsButtons.visible:SetText(db.visible and "Hide Main Frame" or "Show Main Frame")
  end
end

local function ToggleOptionsUI()
  if not optionsFrame then
    return
  end

  if optionsFrame:IsShown() then
    optionsFrame:Hide()
  else
    RefreshOptionsUI()
    optionsFrame:Show()
  end
end

local function NextRoleToken(role)
  if role == "HEALER" then return "TANK" end
  if role == "TANK" then return "DAMAGER" end
  if role == "DAMAGER" then return nil end
  return "HEALER"
end

local function RefreshRoleOverrideUI()
  if not roleFrame or not roleFrame:IsShown() then
    return
  end

  AddGroupUnits()
  local seen = {}
  local list = {}
  for i = 1, #units do
    local unit = units[i]
    if UnitExists(unit) then
      local _, classFile = UnitClass(unit)
      local maxMana = UnitPowerMax(unit, 0) or 0
      if IsManaClass(classFile) and maxMana > 0 then
        local name = UnitName(unit)
        local key = NormalizeName(name)
        if key and not seen[key] then
          seen[key] = true
          list[#list + 1] = { name = name, key = key }
        end
      end
    end
  end

  table.sort(list, function(a, b) return a.name < b.name end)

  for i = 1, #roleRows do
    local row = roleRows[i]
    local item = list[i]
    if item then
      local role = db.roleOverrides[item.key]
      local roleText = role or "AUTO"
      row.name = item.name
      row.key = item.key
      row:SetText(string.format("%s [%s]", item.name, roleText))
      row:Show()
    else
      row.name = nil
      row.key = nil
      row:Hide()
    end
  end
end

local function CreateRoleOverrideUI()
  roleFrame = CreateFrame("Frame", "RaidManaTBCRoleFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  roleFrame:SetSize(270, 270)
  roleFrame:SetPoint("CENTER", UIParent, "CENTER", 250, 0)
  roleFrame:SetFrameStrata("DIALOG")
  roleFrame:SetMovable(true)
  roleFrame:EnableMouse(true)
  roleFrame:RegisterForDrag("LeftButton")
  roleFrame:SetClampedToScreen(true)
  roleFrame:Hide()

  roleFrame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true,
    tileSize = 8,
    edgeSize = 8,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  roleFrame:SetBackdropColor(0, 0, 0, 0.9)
  roleFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

  roleFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  roleFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  roleFrame:SetScript("OnShow", RefreshRoleOverrideUI)

  local title = roleFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  title:SetPoint("TOP", roleFrame, "TOP", 0, -10)
  title:SetText("Role Overrides (Click to Cycle)")

  local note = roleFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  note:SetPoint("TOP", roleFrame, "TOP", 0, -28)
  note:SetText("AUTO -> HEALER -> TANK -> DAMAGER -> AUTO")

  local closeButton = CreateFrame("Button", nil, roleFrame, "UIPanelCloseButton")
  closeButton:SetPoint("TOPRIGHT", roleFrame, "TOPRIGHT", -2, -2)

  for i = 1, 10 do
    local b = CreateFrame("Button", nil, roleFrame, "UIPanelButtonTemplate")
    b:SetSize(230, 20)
    b:SetPoint("TOP", roleFrame, "TOP", 0, -44 - ((i - 1) * 21))
    b:SetScript("OnClick", function(self)
      if not self.key then return end
      if not CanManageOverrides() then
        Msg("Only group leader can edit overrides.")
        return
      end
      local nextRole = NextRoleToken(db.roleOverrides[self.key])
      db.roleOverrides[self.key] = nextRole
      if nextRole then
        BroadcastOverrideSet(self.key, nextRole)
      else
        BroadcastOverrideDelete(self.key)
      end
      MarkDirty()
      RefreshRoleOverrideUI()
    end)
    b:Hide()
    roleRows[i] = b
  end
end

local function HandleSlash(msg)
  local cmd, rest = msg:match("^(%S*)%s*(.-)$")
  local restRaw = rest or ""
  cmd = (cmd or ""):lower()
  rest = restRaw:lower()

  if cmd == "" then
    PrintHelp()
    return
  end

  if cmd == "show" then
    db.visible = true
    mainFrame:Show()
    Msg("Shown.")
    return
  end

  if cmd == "hide" then
    db.visible = false
    mainFrame:Hide()
    Msg("Hidden.")
    return
  end

  if cmd == "lock" then
    db.locked = true
    ApplyFrameSettings()
    Msg("Frame locked.")
    return
  end

  if cmd == "unlock" then
    db.locked = false
    ApplyFrameSettings()
    Msg("Frame unlocked.")
    return
  end

  if cmd == "reset" then
    ResetPosition()
    return
  end

  if cmd == "view" then
    if rest == "all" or rest == "healers" then
      db.view = rest
      MarkDirty()
      Msg("View set to " .. rest .. ".")
    else
      Msg("Usage: /raidmana view all | healers")
    end
    return
  end

  if cmd == "mode" then
    if rest == "weighted" or rest == "mean" then
      db.mode = rest
      MarkDirty()
      Msg("Mode set to " .. rest .. ".")
    else
      Msg("Usage: /raidmana mode weighted | mean")
    end
    return
  end

  if cmd == "sort" then
    if rest == "low" or rest == "high" then
      db.sort = rest
      MarkDirty()
      Msg("Sort set to " .. rest .. ".")
    else
      Msg("Usage: /raidmana sort low | high")
    end
    return
  end

  if cmd == "offline" then
    if rest == "on" then
      db.showOffline = true
      MarkDirty()
      Msg("Offline units enabled.")
    elseif rest == "off" then
      db.showOffline = false
      MarkDirty()
      Msg("Offline units disabled.")
    else
      Msg("Usage: /raidmana offline on | off")
    end
    return
  end

  if cmd == "alerts" then
    if rest == "on" then
      db.healerAlerts = true
      Msg("Healer alerts enabled.")
    elseif rest == "off" then
      db.healerAlerts = false
      Msg("Healer alerts disabled.")
    else
      Msg("Usage: /raidmana alerts on | off")
    end
    RefreshOptionsUI()
    return
  end

  if cmd == "innervate" then
    if rest == "on" then
      db.showInnervateMarkers = true
      MarkDirty()
      Msg("Innervate markers enabled.")
    elseif rest == "off" then
      db.showInnervateMarkers = false
      MarkDirty()
      Msg("Innervate markers disabled.")
    else
      Msg("Usage: /raidmana innervate on | off")
    end
    RefreshOptionsUI()
    return
  end

  if cmd == "sender" then
    if rest == "leader" or rest == "auto" then
      db.alertSenderMode = rest
      Msg("Alert sender mode set to " .. rest .. ".")
    else
      Msg("Usage: /raidmana sender leader | auto")
    end
    RefreshOptionsUI()
    return
  end

  if cmd == "autogroup" then
    if rest == "on" then
      db.autoGroupVisibility = true
      ApplyAutoGroupVisibility()
      ApplyFrameSettings()
      Msg("Auto group visibility enabled.")
    elseif rest == "off" then
      db.autoGroupVisibility = false
      Msg("Auto group visibility disabled.")
    else
      Msg("Usage: /raidmana autogroup on | off")
    end
    return
  end

  if cmd == "readability" then
    if rest == "normal" or rest == "readable" then
      db.readability = rest
      MarkDirty()
      Msg("Readability set to " .. rest .. ".")
    else
      Msg("Usage: /raidmana readability normal | readable")
    end
    return
  end

  do
    local action = nil
    local arg1 = ""
    local arg2 = ""

    if cmd == "override" then
      action, arg1, arg2 = restRaw:match("^(%S+)%s*(%S*)%s*(.-)$")
      action = (action or ""):lower()
      arg1 = arg1 or ""
      arg2 = (arg2 or ""):lower()
    elseif cmd == "set" or cmd == "remove" or cmd == "list" or cmd == "clear" then
      action = cmd
      local a1, a2 = restRaw:match("^(%S*)%s*(.-)$")
      arg1 = a1 or ""
      arg2 = (a2 or ""):lower()
    end

    if action then
      if type(db.roleOverrides) ~= "table" then
        db.roleOverrides = {}
      end

      if action == "set" then
        if not CanManageOverrides() then
          Msg("Only group leader can edit overrides.")
          return
        end
        if arg1 == "" or arg2 == "" then
          Msg("Usage: /raidmana set <name> healer|tank|dps")
          return
        end

        local roleToken = string.upper(arg2)
        if roleToken == "DPS" then
          roleToken = "DAMAGER"
        end

        if roleToken ~= "HEALER" and roleToken ~= "TANK" and roleToken ~= "DAMAGER" then
          Msg("Role must be healer, tank, or dps.")
          return
        end

        local key = NormalizeName(arg1)
        if not key then
          Msg("Invalid name.")
          return
        end

        db.roleOverrides[key] = roleToken
        BroadcastOverrideSet(key, roleToken)
        MarkDirty()
        Msg(string.format("Override set: %s -> %s", key, roleToken))
        return
      end

      if action == "remove" then
        if not CanManageOverrides() then
          Msg("Only group leader can edit overrides.")
          return
        end
        if arg1 == "" then
          Msg("Usage: /raidmana remove <name>")
          return
        end

        local key = NormalizeName(arg1)
        if not key then
          Msg("Invalid name.")
          return
        end

        db.roleOverrides[key] = nil
        BroadcastOverrideDelete(key)
        MarkDirty()
        Msg("Override removed: " .. key)
        return
      end

      if action == "list" then
        local keys = {}
        for name in pairs(db.roleOverrides) do
          keys[#keys + 1] = name
        end
        table.sort(keys)

        if #keys == 0 then
          Msg("No overrides set.")
        else
          Msg("Role overrides:")
          for i = 1, #keys do
            Msg(string.format("- %s: %s", keys[i], db.roleOverrides[keys[i]]))
          end
        end
        return
      end

      if action == "clear" then
        if not CanManageOverrides() then
          Msg("Only group leader can edit overrides.")
          return
        end
        wipe(db.roleOverrides)
        BroadcastOverrideClear()
        MarkDirty()
        Msg("All role overrides cleared.")
        return
      end

      Msg("Usage: /raidmana set|remove|list|clear ...")
      return
    end
  end

  if cmd == "options" then
    ToggleOptionsUI()
    return
  end

  if cmd == "changelog" then
    PrintChangelog()
    return
  end

  PrintHelp()
end

local function CreateOptionsUI()
  optionsFrame = CreateFrame("Frame", "RaidManaTBCOptionsFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  optionsFrame:SetSize(260, 378)
  optionsFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  optionsFrame:SetFrameStrata("DIALOG")
  optionsFrame:SetMovable(true)
  optionsFrame:EnableMouse(true)
  optionsFrame:RegisterForDrag("LeftButton")
  optionsFrame:SetClampedToScreen(true)
  optionsFrame:Hide()

  optionsFrame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true,
    tileSize = 8,
    edgeSize = 8,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  optionsFrame:SetBackdropColor(0, 0, 0, 0.9)
  optionsFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

  optionsFrame:SetScript("OnDragStart", function(self)
    self:StartMoving()
  end)
  optionsFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
  end)

  local title = optionsFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  title:SetPoint("TOP", optionsFrame, "TOP", 0, -10)
  title:SetText("RaidManaTBC Options")

  local closeButton = CreateFrame("Button", nil, optionsFrame, "UIPanelCloseButton")
  closeButton:SetPoint("TOPRIGHT", optionsFrame, "TOPRIGHT", -2, -2)

  local function makeButton(key, yOffset, onClick)
    local b = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
    b:SetSize(220, 22)
    b:SetPoint("TOP", optionsFrame, "TOP", 0, yOffset)
    b:SetScript("OnClick", onClick)
    optionsButtons[key] = b
  end

  makeButton("view", -34, function()
    db.view = (db.view == "all") and "healers" or "all"
    MarkDirty()
    RefreshOptionsUI()
  end)

  makeButton("mode", -60, function()
    db.mode = (db.mode == "weighted") and "mean" or "weighted"
    MarkDirty()
    RefreshOptionsUI()
  end)

  makeButton("sort", -86, function()
    db.sort = (db.sort == "low") and "high" or "low"
    MarkDirty()
    RefreshOptionsUI()
  end)

  makeButton("offline", -112, function()
    db.showOffline = not db.showOffline
    MarkDirty()
    RefreshOptionsUI()
  end)

  makeButton("alerts", -138, function()
    db.healerAlerts = not db.healerAlerts
    RefreshOptionsUI()
  end)

  makeButton("innervateMarkers", -164, function()
    db.showInnervateMarkers = not db.showInnervateMarkers
    MarkDirty()
    RefreshOptionsUI()
  end)

  makeButton("sender", -190, function()
    db.alertSenderMode = (db.alertSenderMode == "leader") and "auto" or "leader"
    RefreshOptionsUI()
  end)

  makeButton("autogroup", -216, function()
    db.autoGroupVisibility = not db.autoGroupVisibility
    ApplyAutoGroupVisibility()
    ApplyFrameSettings()
    RefreshOptionsUI()
  end)

  makeButton("readability", -242, function()
    db.readability = (db.readability == "readable") and "normal" or "readable"
    MarkDirty()
    RefreshOptionsUI()
  end)

  makeButton("roles", -268, function()
    if not roleFrame then
      return
    end
    if roleFrame:IsShown() then
      roleFrame:Hide()
    else
      RefreshRoleOverrideUI()
      roleFrame:Show()
    end
  end)
  optionsButtons.roles:SetText("Role Overrides")

  makeButton("lock", -294, function()
    db.locked = not db.locked
    ApplyFrameSettings()
    RefreshOptionsUI()
  end)

  makeButton("visible", -320, function()
    db.visible = not db.visible
    ApplyFrameSettings()
    RefreshOptionsUI()
  end)

  makeButton("reset", -346, function()
    ResetPosition()
    RefreshOptionsUI()
  end)
  optionsButtons.reset:SetText("Reset Position")

  optionsFrame:SetScript("OnShow", RefreshOptionsUI)
end

local function CreateMainFrame()
  mainFrame = CreateFrame("Frame", "RaidManaTBCFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  mainFrame:SetWidth(220)
  mainFrame:SetHeight(32)
  mainFrame:SetClampedToScreen(true)
  mainFrame:SetMovable(true)
  mainFrame:EnableMouse(true)
  mainFrame:RegisterForDrag("LeftButton")

  if ENABLE_BACKGROUND then
    mainFrame:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true,
      tileSize = 8,
      edgeSize = 8,
      insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    mainFrame:SetBackdropColor(0, 0, 0, 0.25)
    mainFrame:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.6)
  end

  mainFrame:SetScript("OnDragStart", function(self)
    if not db.locked then
      self:StartMoving()
    end
  end)

  mainFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    SaveFramePosition()
  end)

  headerText = mainFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  headerText:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 6, -6)
  headerText:SetJustifyH("LEFT")
  headerText:SetText("Average Mana (All): 0.0%")

  for i = 1, MAX_LINES do
    local fs = mainFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetJustifyH("LEFT")
    fs:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 6, -6 - (i * 13))
    fs:Hide()
    linePool[i] = fs
  end

  mainFrame:SetScript("OnUpdate", function(_, elapsed)
    elapsedSinceUpdate = elapsedSinceUpdate + elapsed
    commElapsed = commElapsed + elapsed
    if elapsedSinceUpdate < UPDATE_INTERVAL then return end
    elapsedSinceUpdate = 0

    if commElapsed >= COMM_INTERVAL then
      commElapsed = 0
      if IsInGroupNow() then
        local selfKey = GetPlayerKey()
        if selfKey then
          addonPeersByName[selfKey] = GetTime and GetTime() or 0
        end
        SendAddonPing()
      end
    end

    if dirty then
      dirty = false
      if mainFrame:IsShown() then
        Render()
      else
        BuildEntries()
      end
    end
  end)
end

local function CreateMinimapButton()
  local libStub = _G.LibStub
  if not libStub then
    Msg("LibStub not found. Minimap button disabled.")
    return
  end

  local ldb = libStub("LibDataBroker-1.1", true)
  libDBIcon = libStub("LibDBIcon-1.0", true)

  if not ldb or not libDBIcon then
    Msg("LibDataBroker-1.1 / LibDBIcon-1.0 not found. Minimap button disabled.")
    return
  end

  SyncMinimapSettings()

  ldbObject = ldb:NewDataObject(ADDON_NAME, {
    type = "data source",
    text = ADDON_NAME,
    icon = "Interface\\Icons\\Spell_Nature_Lightning",
    OnClick = function(_, button)
      if button == "LeftButton" then
        db.visible = not db.visible
        if db.visible then
          mainFrame:Show()
        else
          mainFrame:Hide()
        end
      elseif button == "RightButton" then
        ToggleOptionsUI()
      end
    end,
    OnTooltipShow = function(tooltip)
      tooltip:AddLine("RaidManaTBC")
      tooltip:AddLine("Left Click: Show/Hide", 0.8, 0.8, 0.8)
      tooltip:AddLine("Right Click: Options UI", 0.8, 0.8, 0.8)
      tooltip:AddLine("Drag: Move button", 0.8, 0.8, 0.8)
    end,
  })

  libDBIcon:Register(ADDON_NAME, ldbObject, db.minimap)
  RefreshMinimapButton()
end

local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4)
  if event == "ADDON_LOADED" then
    if arg1 ~= ADDON_NAME then return end

    _G[DB_NAME] = _G[DB_NAME] or {}
    db = _G[DB_NAME]
    CopyDefaults(db, DEFAULTS)
    SyncMinimapSettings()
    RegisterAddonPrefix()

    CreateMainFrame()
    CreateRoleOverrideUI()
    CreateOptionsUI()
    CreateMinimapButton()
    ApplyAutoGroupVisibility()
    ApplyFrameSettings()

    SLASH_RAIDMANATBC1 = "/raidmana"
    SLASH_RAIDMANATBC2 = "/rmana"
    SlashCmdList.RAIDMANATBC = HandleSlash

    MarkDirty()
    return
  end

  if event == "CHAT_MSG_ADDON" then
    local prefix = arg1
    local msg = arg2
    local senderName = arg4

    if prefix ~= COMM_PREFIX then
      return
    end

    if msg == "PING" and senderName then
      local senderKey = NormalizeName(senderName)
      if senderKey then
        addonPeersByName[senderKey] = GetTime and GetTime() or 0
        local myKey = GetPlayerKey()
        local leaderKey = GetGroupLeaderKey()
        if CanManageOverrides() and myKey and leaderKey and myKey == leaderKey then
          BroadcastOverrideFullSync()
        end
      end
      return
    end

    if senderName then
      local senderKey = NormalizeName(senderName)
      local leaderKey = GetGroupLeaderKey()
      if not senderKey or not leaderKey or senderKey ~= leaderKey then
        return
      end

      if string.sub(msg, 1, 9) == "OVR_FULL:" then
        ApplySerializedOverrides(string.sub(msg, 10))
      elseif string.sub(msg, 1, 8) == "OVR_SET:" then
        local key, role = string.match(string.sub(msg, 9), "^([^:]+):([^:]+)$")
        if key and IsValidRole(role) then
          if type(db.roleOverrides) ~= "table" then db.roleOverrides = {} end
          db.roleOverrides[key] = role
          MarkDirty()
        end
      elseif string.sub(msg, 1, 8) == "OVR_DEL:" then
        local key = string.sub(msg, 9)
        if key and key ~= "" then
          if type(db.roleOverrides) ~= "table" then db.roleOverrides = {} end
          db.roleOverrides[key] = nil
          MarkDirty()
        end
      elseif msg == "OVR_CLR" then
        if type(db.roleOverrides) ~= "table" then db.roleOverrides = {} end
        wipe(db.roleOverrides)
        MarkDirty()
      end
    end
    return
  end

  if event == "PLAYER_ENTERING_WORLD" or event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" or event == "GROUP_ROSTER_UPDATE" then
    ApplyAutoGroupVisibility()
    ApplyFrameSettings()
    local selfKey = GetPlayerKey()
    if selfKey then
      addonPeersByName[selfKey] = GetTime and GetTime() or 0
    end
    SendAddonPing()
    BroadcastOverrideFullSync()
    if roleFrame and roleFrame:IsShown() then
      RefreshRoleOverrideUI()
    end
    MarkDirty()
    return
  end

  if event == "UNIT_POWER" or event == "UNIT_POWER_UPDATE" or event == "UNIT_POWER_FREQUENT" or event == "UNIT_MAXPOWER" then
    if arg2 and arg2 ~= "MANA" and arg2 ~= 0 and arg2 ~= "0" then
      return
    end
    MarkDirty()
    return
  end

  if event == "COMBAT_LOG_EVENT_UNFILTERED" then
    HandleCombatLogEvent()
    return
  end
end)

eventFrame:RegisterEvent("ADDON_LOADED")
SafeRegister(eventFrame, "PLAYER_ENTERING_WORLD")
SafeRegister(eventFrame, "RAID_ROSTER_UPDATE")
SafeRegister(eventFrame, "PARTY_MEMBERS_CHANGED")
SafeRegister(eventFrame, "GROUP_ROSTER_UPDATE")
SafeRegister(eventFrame, "UNIT_POWER_UPDATE")
SafeRegister(eventFrame, "UNIT_POWER")
SafeRegister(eventFrame, "UNIT_POWER_FREQUENT")
SafeRegister(eventFrame, "UNIT_MAXPOWER")
SafeRegister(eventFrame, "CHAT_MSG_ADDON")
SafeRegister(eventFrame, "COMBAT_LOG_EVENT_UNFILTERED")
