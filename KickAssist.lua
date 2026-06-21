local ADDON = ...

--------------------------------------------------------------------------------
-- Kick Assist
-- Pick your interrupt (kick) raid marker, announce it to the group, and keep
-- your interrupt macro's marker number in sync with your pick. The popup
-- auto-shows on ready check and / or Mythic+ start.
--
-- Marking note: SetRaidTarget is a PROTECTED function (addons may not call it).
-- The game already ships a secure /tm command (Blizzard's TARGET_MARKER slash)
-- that does the marking. This addon never calls SetRaidTarget and never registers
-- /tm; it only rewrites the marker NUMBER inside your macro so the built-in /tm
-- marks with whatever you picked.
--
-- Announce note: a message sent from a button click is always allowed. Automated
-- announce on the trigger works outside instanced content; inside an instance it
-- can be blocked, in which case the button still works.
--------------------------------------------------------------------------------

-- {interrupt} = your spec's interrupt, {kick} = your marker. The ~ before {kick}
-- marks only if the target has no marker yet, so re-pressing never removes/overwrites
-- a mark. The default Focus+Kick casts before setting focus, so the first press sets
-- focus and the next press kicks it (no modifier, no mouseover).
local DEFAULT_MACRO =
	"#showtooltip {interrupt}\n" ..
	"/cast [@focus,harm,nodead] {interrupt}\n" ..
	"/focus [@focus,noexists] target\n" ..
	"/tm [@target,noexists][@target,dead] ~{kick}; ~{kick}"

-- Set focus + mark; no #showtooltip so it keeps the targeting icon.
local SET_FOCUS_MACRO =
	"/focus target\n" ..
	"/tm [@target,noexists][@target,dead] ~{kick}; ~{kick}"

-- Auto tab kick (default): tab to the nearest enemy, interrupt, return to your target.
local AUTOTAB_MACRO =
	"#showtooltip {interrupt}\n" ..
	"/cleartarget\n" ..
	"/targetenemy\n" ..
	"/cast {interrupt}\n" ..
	"/targetlasttarget"

-- Auto tab kick (focus first): kick your focus if you have one, else tab-interrupt
-- a casting mob without losing your current target.
local AUTOTAB_FOCUS_MACRO =
	"#showtooltip {interrupt}\n" ..
	"/cast [@focus,exists,nodead,harm] {interrupt}\n" ..
	"/stopmacro [@focus,exists,nodead,harm]\n" ..
	"/focus target\n" ..
	"/cleartarget\n" ..
	"/targetenemy\n" ..
	"/cast {interrupt}\n" ..
	"/target focus\n" ..
	"/clearfocus\n" ..
	"/startattack"

-- Auto tab kick (mouseover override): kick your mouseover or focus if valid, else
-- tab-interrupt without losing your current target.
local AUTOTAB_MOUSEOVER_MACRO =
	"#showtooltip\n" ..
	"/cast [@mouseover,harm,nodead][@focus,harm,nodead,exists] {interrupt}\n" ..
	"/stopmacro [@mouseover,harm,nodead][@focus,harm,nodead,exists]\n" ..
	"/focus target\n" ..
	"/cleartarget\n" ..
	"/targetenemy\n" ..
	"/cast {interrupt}\n" ..
	"/target focus\n" ..
	"/clearfocus"

-- Templates per macro slot: the editor shows the set for whichever macro is selected.
local TEMPLATES = {
	kick = {
		{ name = "Focus + Kick (default, re-press to kick)", body = DEFAULT_MACRO },
		{ name = "Focus + Kick (Ctrl to kick your target)",
		  body = "#showtooltip {interrupt}\n/cast [nomod:ctrl,@focus,harm,nodead][] {interrupt}\n/focus [@focus,noexists] target\n/tm [@target,noexists][@target,dead] ~{kick}; ~{kick}" },
		{ name = "Focus + Kick (mouseover)",
		  body = "#showtooltip {interrupt}\n/cast [@focus,harm,nodead] {interrupt}\n/focus [@mouseover,harm,nodead,exists] mouseover\n/tm [@mouseover,exists][] ~{kick}" },
	},
	focus = {
		{ name = "Set focus (target)", body = SET_FOCUS_MACRO },
		{ name = "Set focus (mouseover)",
		  body = "/focus [@mouseover,exists] mouseover\n/tm [@mouseover,exists][] ~{kick}" },
	},
	autotab = {
		{ name = "Auto Tab Kick (tab to nearest)", body = AUTOTAB_MACRO },
		{ name = "Auto Tab Kick (focus first, else tab)", body = AUTOTAB_FOCUS_MACRO },
		{ name = "Auto Tab Kick (mouseover or focus, else tab)", body = AUTOTAB_MOUSEOVER_MACRO },
	},
}

-- The three macro slots the editor can edit (Focus+Kick, Set Focus, Auto Tab Kick).
local SLOT_CFG = {
	kick    = { label = "Focus + Kick",  nameKey = "macroName",    tmplKey = "macroTemplate",    defName = "FocusKick",   defBody = DEFAULT_MACRO },
	focus   = { label = "Set Focus",     nameKey = "setFocusName", tmplKey = "setFocusTemplate", defName = "SetFocus",    defBody = SET_FOCUS_MACRO },
	autotab = { label = "Auto Tab Kick", nameKey = "autoTabName",  tmplKey = "autoTabTemplate",  defName = "AutoTabKick", defBody = AUTOTAB_MACRO },
}
local SLOT_ORDER = { "kick", "focus", "autotab" }

local DEFAULTS = {
	marker               = 8,            -- 1..8 raid target index, 0 = no marker (skull default)
	showOnReadyCheck     = true,         -- show on ready check while in a Mythic+ dungeon
	announceOnReadyCheck = true,         -- post your kick to chat on a ready check (sends before a key; auto-skips once chat is locked)
	-- Which instances the ready-check popup/announce fires in (default: Mythic dungeons only).
	contexts             = { mplus = true, mythic = true, heroic = false, normal = false, raid = false },
	autoAnnounce         = false,        -- announce automatically when the popup opens (off: click to announce)
	message              = "My Focus Kick is %MARKER%",
	point                = { "CENTER", "CENTER", 0, 140 },

	macroEnabled         = false,        -- opt-in: do not touch macros until the user enables it
	macroName            = "FocusKick",  -- set-focus-and-kick macro
	macroTemplate        = DEFAULT_MACRO,
	setFocusName         = "SetFocus",   -- set-focus-and-mark macro
	setFocusTemplate     = SET_FOCUS_MACRO,
	autoTabName          = "AutoTabKick",-- auto tab-interrupt macro
	autoTabTemplate      = AUTOTAB_MACRO,
	macroPoint           = { "CENTER", "CENTER", 0, 0 },

	minimap              = { angle = 214, hide = false },
}

local MARKER_NAMES = {
	[0] = "No Marker",
	"Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "Cross", "Skull",
}

local PREFIX = "|cff33ff99Kick Assist|r: "
local QUESTION_ICON = "INV_Misc_QuestionMark"
local FOCUS_ICON = 132212  -- set-focus macro icon (fileID)

local DB           -- resolved at ADDON_LOADED
local frame        -- main popup, created lazily
local macroFrame   -- macro editor, created lazily
local settingsCategory  -- Blizzard settings category (set in CreateSettingsPanel)

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Chat substitution token for a raid marker; the chat system renders the icon.
local function ChatToken(index)
	if index and index >= 1 and index <= 8 then
		return "{rt" .. index .. "}"
	end
	return "no marker"
end

-- Set a texture to a single cell of the 4x4 raid-target sprite sheet.
local function SetMarkerTexture(tex, index)
	tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
	local col  = (index - 1) % 4
	local row  = math.floor((index - 1) / 4)
	local left = col * 0.25
	local top  = row * 0.25
	tex:SetTexCoord(left, left + 0.25, top, top + 0.25)
end

-- Where group chat should go right now (nil = not grouped).
local function GroupChannel()
	if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
	if IsInRaid() then return "RAID" end
	if IsInGroup() then return "PARTY" end
	return nil
end

-- Trigger contexts the popup/announce can fire in. Difficulty IDs (DifficultyUtil):
-- 1 Normal, 2 Heroic, 23 Mythic, 8 Mythic Keystone (M+); raids via instanceType.
local CONTEXT_DEFAULTS = { mplus = true, mythic = true, heroic = false, normal = false, raid = false }
local CONTEXT_ORDER    = { "mplus", "mythic", "heroic", "normal", "raid" }
local CONTEXT_LABELS   = {
	mplus  = "Mythic+ (keystone)",
	mythic = "Mythic dungeon",
	heroic = "Heroic dungeon",
	normal = "Normal dungeon",
	raid   = "Raids",
}

-- Which trigger context (if any) the player is currently in.
local function CurrentContextKey()
	local inInstance, instanceType = IsInInstance()
	if not inInstance then return nil end
	if instanceType == "raid" then return "raid" end
	if instanceType == "party" then
		local diff = select(3, GetInstanceInfo())
		if diff == 8  then return "mplus"  end
		if diff == 23 then return "mythic" end
		if diff == 2  then return "heroic" end
		if diff == 1  then return "normal" end
	end
	return nil
end

-- Is this context enabled? Falls back to the default when the player hasn't set it.
local function ContextEnabled(key)
	local v = DB.contexts and DB.contexts[key]
	if v == nil then v = CONTEXT_DEFAULTS[key] end
	return v and true or false
end

-- True when the current instance is one the player enabled for the popup/announce.
local function ShouldTriggerHere()
	local key = CurrentContextKey()
	return key ~= nil and ContextEnabled(key)
end

-- True when addons may post to chat right now. The Chat restriction
-- (Enum.AddOnRestrictionType.Chat) is OFF before a Mythic+ key starts and flips
-- ON once the key is active, where an addon SendChatMessage is blocked. Checking
-- it lets the ready-check announce go out before the key and stand down after it,
-- with no blocked-action error. C_RestrictedActions is 12.0+; guarded for safety.
local function ChatAllowed()
	local C = C_RestrictedActions
	if C and C.IsAddOnRestrictionActive and Enum and Enum.AddOnRestrictionType then
		return not C.IsAddOnRestrictionActive(Enum.AddOnRestrictionType.Chat)
	end
	return true
end

-- Interrupt ("kick") spell per class, with spec overrides keyed by specialization
-- ID. Verified against warcraft.wiki.gg/wiki/Interrupt. Missing = spec has no kick.
local INTERRUPTS = {
	DEATHKNIGHT = { default = 47528  },                  -- Mind Freeze
	DEMONHUNTER = { default = 183752 },                  -- Disrupt
	DRUID       = { default = 106839, [102] = 78675  },  -- Skull Bash; Balance = Solar Beam
	EVOKER      = { default = 351338 },                  -- Quell
	HUNTER      = { default = 147362, [255] = 187707 },  -- Counter Shot; Survival = Muzzle
	MAGE        = { default = 2139   },                  -- Counterspell
	MONK        = { default = 116705 },                  -- Spear Hand Strike
	PALADIN     = { default = 96231  },                  -- Rebuke (all specs)
	PRIEST      = {                   [258] = 15487 },   -- Shadow = Silence; Disc/Holy none
	ROGUE       = { default = 1766   },                  -- Kick
	SHAMAN      = { default = 57994  },                  -- Wind Shear
	WARLOCK     = { default = 19647  },                  -- Spell Lock (Felhunter pet)
	WARRIOR     = { default = 6552   },                  -- Pummel
}

-- The current character's interrupt spell ID (nil if this spec has none).
local function GetMyInterruptID()
	local _, classToken = UnitClass("player")
	local data = classToken and INTERRUPTS[classToken]
	if not data then return nil end
	local specIndex = GetSpecialization()
	local specID = specIndex and GetSpecializationInfo(specIndex)
	return (specID and data[specID]) or data.default
end

local function GetMyInterruptName()
	local id = GetMyInterruptID()
	return id and C_Spell.GetSpellName(id) or nil
end

-- Post the kick marker to group chat. `fromTrigger` = fired by an event (e.g. the
-- ready check) rather than a click; on a trigger we stay silent when we can't send.
-- We never send while chat is locked (an active Mythic+ key), so this never throws
-- a blocked-action error -- whether called from a click or the ready-check trigger.
local function Announce(fromTrigger)
	local token   = ChatToken(DB.marker)
	local msg     = (tostring(DB.message or DEFAULTS.message):gsub("%%MARKER%%", token))
	local channel = GroupChannel()
	if not channel then
		if not fromTrigger then print(PREFIX .. msg .. " (not in a group, shown locally)") end
		return
	end
	if not ChatAllowed() then
		if not fromTrigger then print(PREFIX .. "chat is locked right now (Mythic+ in progress); announce skipped.") end
		return
	end
	SendChatMessage(msg, channel)
end

--------------------------------------------------------------------------------
-- Macro management (text only; the built-in /tm does the marking)
--------------------------------------------------------------------------------

-- Swap marker numbers (0-8) that are real /tm arguments for a replacement, while
-- leaving any digits inside [condition] brackets alone. Returns the new string and
-- the number of markers replaced.
local function ReplaceTmMarkers(s, replacement)
	local out, depth, count = {}, 0, 0
	for i = 1, #s do
		local c = s:sub(i, i)
		if c == "[" then
			depth = depth + 1; out[#out + 1] = c
		elseif c == "]" then
			if depth > 0 then depth = depth - 1 end
			out[#out + 1] = c
		elseif depth == 0 and c >= "0" and c <= "8" then
			out[#out + 1] = replacement; count = count + 1
		else
			out[#out + 1] = c
		end
	end
	return table.concat(out), count
end

-- Make an existing macro body marker-managed for the "pick existing macro" flow:
-- in its first /tm line swap the marker number(s) for {kick} (adding ~{kick} if that
-- line has no number yet); if there is no /tm line at all, append one. Everything
-- else in the macro is left exactly as the player wrote it.
local function ManageMarkerInBody(body)
	body = tostring(body or ""):gsub("[\r\n]+$", "")
	if body == "" then return "/tm [@target,noexists][@target,dead] ~{kick}; ~{kick}" end
	local lines, handled = {}, false
	for line in (body .. "\n"):gmatch("(.-)\n") do
		if not handled then
			local prefix, rest = line:match("^(%s*/[tT][mM])(.*)$")
			if prefix and (rest == "" or rest:match("^[%s%[~!0-8]")) then
				local newRest, n = ReplaceTmMarkers(rest, "{kick}")
				line = prefix .. newRest
				if n == 0 then line = line .. " ~{kick}" end
				handled = true
			end
		end
		lines[#lines + 1] = line
	end
	if not handled then
		lines[#lines + 1] = "/tm [@target,noexists][@target,dead] ~{kick}; ~{kick}"
	end
	return table.concat(lines, "\n")
end

-- Rewrite the managed macro so {kick} matches the chosen marker. Out of combat
-- only (EditMacro / CreateMacro are blocked in combat).
local function UpdateManagedMacro()
	if not (DB and DB.macroEnabled) then return end
	if InCombatLockdown() then return end

	local name = DB.macroName ~= "" and DB.macroName or DEFAULTS.macroName
	local interrupt = GetMyInterruptName() or ""
	local body = tostring(DB.macroTemplate or DEFAULT_MACRO)
	body = body:gsub("{interrupt}", interrupt):gsub("{kick}", tostring(DB.marker))
	if body == "" then return end

	local idx = GetMacroIndexByName(name)
	if idx and idx > 0 then
		EditMacro(idx, name, QUESTION_ICON, body)
	else
		local _, numChar = GetNumMacros()
		if numChar and numChar >= MAX_CHARACTER_MACROS then
			print(PREFIX .. "no free character macro slots for '" .. name .. "'.")
			return
		end
		CreateMacro(name, QUESTION_ICON, body, true) -- per-character
	end
end

-- The fixed "set focus + mark" macro. Synced if it exists; created when create=true.
local function UpdateSetFocusMacro(create)
	if InCombatLockdown() then return end
	local name = DB.setFocusName ~= "" and DB.setFocusName or DEFAULTS.setFocusName
	local interrupt = GetMyInterruptName() or ""
	local body = tostring(DB.setFocusTemplate or SET_FOCUS_MACRO):gsub("{interrupt}", interrupt):gsub("{kick}", tostring(DB.marker))
	local idx = GetMacroIndexByName(name)
	if idx and idx > 0 then
		EditMacro(idx, name, FOCUS_ICON, body)
	elseif create then
		local _, numChar = GetNumMacros()
		if numChar and numChar >= MAX_CHARACTER_MACROS then
			print(PREFIX .. "no free character macro slots for '" .. name .. "'.")
			return
		end
		CreateMacro(name, FOCUS_ICON, body, true)
	end
end

-- The auto-tab-interrupt macro. Synced if it exists; created when create=true.
local function UpdateAutoTabMacro(create)
	if InCombatLockdown() then return end
	local name = DB.autoTabName ~= "" and DB.autoTabName or DEFAULTS.autoTabName
	local interrupt = GetMyInterruptName() or ""
	local body = tostring(DB.autoTabTemplate or AUTOTAB_MACRO):gsub("{interrupt}", interrupt):gsub("{kick}", tostring(DB.marker))
	local idx = GetMacroIndexByName(name)
	if idx and idx > 0 then
		EditMacro(idx, name, QUESTION_ICON, body)
	elseif create then
		local _, numChar = GetNumMacros()
		if numChar and numChar >= MAX_CHARACTER_MACROS then
			print(PREFIX .. "no free character macro slots for '" .. name .. "'.")
			return
		end
		CreateMacro(name, QUESTION_ICON, body, true)
	end
end

-- Keep all managed macros in sync with the chosen marker; only edits ones that exist.
local function SyncMacros()
	UpdateManagedMacro()
	UpdateSetFocusMacro(false)
	UpdateAutoTabMacro(false)
end

--------------------------------------------------------------------------------
-- Main popup UI
--------------------------------------------------------------------------------

local function UpdateSelection()
	if not frame then return end
	for i = 1, 8 do
		frame.markerButtons[i].sel:SetShown(DB.marker == i)
	end
	frame.noneButton.sel:SetShown(DB.marker == 0)
end

local function MakeSelTexture(parent)
	local t = parent:CreateTexture(nil, "OVERLAY")
	t:SetTexture("Interface\\Buttons\\CheckButtonHilight")
	t:SetBlendMode("ADD")
	t:SetPoint("TOPLEFT", -3, 3)
	t:SetPoint("BOTTOMRIGHT", 3, -3)
	t:Hide()
	return t
end

local function MakeCheck(parent, label, x, y, get, set)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetPoint("TOPLEFT", x, y)
	cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
	local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	fs:SetText(label)
	cb.Refresh = function(self) self:SetChecked(get() and true or false) end
	return cb
end

local function RefreshDragIcons()
	if not frame or not frame.dragIcons then return end
	local id = GetMyInterruptID()
	local spellTex = (id and C_Spell.GetSpellTexture(id)) or 134400
	if frame.dragIcons.kick then
		frame.dragIcons.kick:SetTexture(spellTex)
		frame.dragIcons.kick:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	end
	if frame.dragIcons.autotab then
		frame.dragIcons.autotab:SetTexture(spellTex)
		frame.dragIcons.autotab:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	end
	if frame.dragIcons.focus then
		if type(FOCUS_ICON) == "number" then
			frame.dragIcons.focus:SetTexture(FOCUS_ICON)
		else
			frame.dragIcons.focus:SetTexture("Interface\\Icons\\" .. FOCUS_ICON)
		end
		frame.dragIcons.focus:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	end
end

local function CreateUI()
	if frame then return frame end

	frame = CreateFrame("Frame", "KickAssistFrame", UIParent, "BackdropTemplate")
	frame:SetSize(300, 476)
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:SetBackdrop({
		bgFile   = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = false, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	frame:SetBackdropColor(0.04, 0.04, 0.04, 0.9)

	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local p, _, rp, x, y = self:GetPoint()
		DB.point = { p, rp, x, y }
	end)

	tinsert(UISpecialFrames, "KickAssistFrame")

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -16)
	title:SetText("Kick Assist")

	local instr = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	instr:SetPoint("TOP", title, "BOTTOM", 0, -6)
	instr:SetText("Pick your kick marker")

	-- 8 marker buttons, 4 per row.
	frame.markerButtons = {}
	for i = 1, 8 do
		local btn = CreateFrame("Button", nil, frame)
		btn:SetSize(40, 40)
		local col = (i - 1) % 4
		local row = math.floor((i - 1) / 4)
		btn:SetPoint("TOPLEFT", 55 + col * 50, -58 - row * 50)

		local icon = btn:CreateTexture(nil, "ARTWORK")
		icon:SetAllPoints()
		SetMarkerTexture(icon, i)

		btn.sel = MakeSelTexture(btn)
		btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
		btn:SetScript("OnClick", function()
			DB.marker = i
			UpdateSelection()
			RefreshDragIcons()
			SyncMacros()
			Announce()
		end)
		btn:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(MARKER_NAMES[i])
			GameTooltip:Show()
		end)
		btn:SetScript("OnLeave", GameTooltip_Hide)

		frame.markerButtons[i] = btn
	end

	-- "No Marker" choice.
	local none = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	none:SetSize(100, 22)
	none:SetPoint("TOP", 0, -162)
	none:SetText("No Marker")
	none.sel = MakeSelTexture(none)
	none:SetScript("OnClick", function()
		DB.marker = 0
		UpdateSelection()
		RefreshDragIcons()
		SyncMacros()
	end)
	frame.noneButton = none

	-- Toggles.
	frame.readyCB = MakeCheck(frame, "Show on ready check", 22, -196,
		function() return DB.showOnReadyCheck end,
		function(v) DB.showOnReadyCheck = v end)

	frame.autoCB = MakeCheck(frame, "Auto-announce when opened", 22, -220,
		function() return DB.autoAnnounce end,
		function(v) DB.autoAnnounce = v end)

	frame.announceCB = MakeCheck(frame, "Announce on ready check", 22, -244,
		function() return DB.announceOnReadyCheck end,
		function(v) DB.announceOnReadyCheck = v end)

	-- Editable announce message. %MARKER% is replaced with your marker icon.
	local msgLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	msgLabel:SetPoint("TOPLEFT", 22, -274)
	msgLabel:SetText("Message (%MARKER% = your icon):")

	local msgBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	msgBox:SetSize(246, 20)
	msgBox:SetPoint("TOPLEFT", 28, -292)
	msgBox:SetAutoFocus(false)
	msgBox:SetText(DB.message or DEFAULTS.message)
	msgBox:SetScript("OnEscapePressed", msgBox.ClearFocus)
	msgBox:SetScript("OnEnterPressed", function(self)
		DB.message = self:GetText()
		self:ClearFocus()
	end)
	msgBox:SetScript("OnEditFocusLost", function(self) DB.message = self:GetText() end)
	frame.msgBox = msgBox

	-- Announce: always allowed from a click.
	local announce = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	announce:SetSize(170, 26)
	announce:SetPoint("TOP", 0, -324)
	announce:SetText("Announce to Group")
	announce:SetScript("OnClick", function()
		DB.message = msgBox:GetText()
		Announce()
	end)

	-- Edit Macro + Options sit side by side on one row.
	local macroBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	macroBtn:SetSize(140, 24)
	macroBtn:SetPoint("TOP", -73, -358)
	macroBtn:SetText("Edit Macro...")
	macroBtn:SetScript("OnClick", function() KickAssist_ShowMacroEditor() end)

	-- Opens the Blizzard options page (instance filter for when to open/announce, minimap).
	local optionsBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	optionsBtn:SetSize(140, 24)
	optionsBtn:SetPoint("TOP", 73, -358)
	optionsBtn:SetText("Options...")
	optionsBtn:SetScript("OnClick", function()
		if settingsCategory then Settings.OpenToCategory(settingsCategory:GetID()) end
	end)

	-- Drag-to-bars: two ready macros new users can drop straight onto their bars.
	local dragHeader = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	dragHeader:SetPoint("TOP", 0, -384)
	dragHeader:SetText("New? Drag a macro to your action bar:")

	frame.dragIcons = {}

	local function PickupSlot(nameKey, defName, updateFn)
		if InCombatLockdown() then return end
		local name = (DB[nameKey] and DB[nameKey] ~= "") and DB[nameKey] or defName
		updateFn(true)
		local idx = GetMacroIndexByName(name)
		if idx and idx > 0 then PickupMacro(idx) end
	end

	local function MakeDragBox(xOff, labelText, desc, key, pickup)
		local box = CreateFrame("Button", nil, frame, "BackdropTemplate")
		box:SetSize(40, 40)
		box:SetPoint("TOP", xOff, -402)
		box:RegisterForDrag("LeftButton")
		box:RegisterForClicks("LeftButtonUp")
		box:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
		box:SetBackdropBorderColor(1, 0.82, 0, 0.9)
		local ic = box:CreateTexture(nil, "ARTWORK")
		ic:SetPoint("TOPLEFT", 2, -2)
		ic:SetPoint("BOTTOMRIGHT", -2, 2)
		box:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
		frame.dragIcons[key] = ic
		box:SetScript("OnDragStart", pickup)
		box:SetScript("OnClick", pickup)
		box:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(labelText)
			GameTooltip:AddLine(desc, 1, 1, 1, true)
			GameTooltip:AddLine("Drag onto an action bar, or click then a bar slot.", 0.6, 0.6, 0.6, true)
			GameTooltip:Show()
		end)
		box:SetScript("OnLeave", GameTooltip_Hide)
		local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		lbl:SetPoint("TOP", box, "BOTTOM", 0, -4)
		lbl:SetText(labelText)
		return box
	end

	MakeDragBox(-78, "Focus + Kick", "Interrupts your focus. First press focuses your target, then re-press to kick.", "kick", function()
		DB.macroEnabled = true
		PickupSlot("macroName", DEFAULTS.macroName, UpdateManagedMacro)
	end)
	MakeDragBox(0, "Set Focus", "Sets your current target as your focus and marks it.", "focus", function()
		PickupSlot("setFocusName", DEFAULTS.setFocusName, UpdateSetFocusMacro)
	end)
	MakeDragBox(78, "Tab Kick", "Interrupts the nearest casting enemy, then returns to your target.", "autotab", function()
		PickupSlot("autoTabName", DEFAULTS.autoTabName, UpdateAutoTabMacro)
	end)
	RefreshDragIcons()

	local p = DB.point or DEFAULTS.point
	frame:ClearAllPoints()
	frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])

	frame:Hide()
	return frame
end

local function ShowUI(fromEvent)
	if InCombatLockdown() then
		-- Only tell the user when THEY asked (a trigger like a mid-key ready check stays silent).
		if not fromEvent then print(PREFIX .. "in combat, not opening (this is an out-of-combat tool).") end
		return
	end
	CreateUI()
	UpdateSelection()
	frame.readyCB:Refresh()
	frame.autoCB:Refresh()
	frame.announceCB:Refresh()
	frame.msgBox:SetText(DB.message or DEFAULTS.message)
	RefreshDragIcons()
	SyncMacros()
	frame:Show()
	frame:Raise()
	-- Auto-announce only when YOU opened it (a click or /ka). On a trigger like the
	-- ready check (fromEvent), skip it: an automated SendChatMessage inside an instance
	-- is blocked. Your marker/Announce clicks are hardware events and always send.
	if DB.autoAnnounce and not fromEvent then Announce() end
end

-- Global opener so ArcUI (or any addon) can open the window.
KickAssist_Show = ShowUI

--------------------------------------------------------------------------------
-- Macro editor UI
--------------------------------------------------------------------------------

local editorSlot = "kick"  -- which macro the editor edits: "kick" or "focus"

local function MacroNoteText()
	return "{interrupt} fills in your interrupt (now: " ..
		(GetMyInterruptName() or "none for this spec") .. "); {kick} fills in your marker."
end

function KickAssist_ShowMacroEditor()
	if macroFrame then
		macroFrame.note:SetText(MacroNoteText())
		macroFrame:Show()
		macroFrame:Raise()
		macroFrame.ReloadFields()
		return
	end

	macroFrame = CreateFrame("Frame", "KickAssistMacroFrame", UIParent, "BackdropTemplate")
	macroFrame:SetSize(420, 416)
	macroFrame:SetFrameStrata("DIALOG")
	macroFrame:SetToplevel(true)
	macroFrame:SetClampedToScreen(true)
	macroFrame:SetBackdrop({
		bgFile   = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = false, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	macroFrame:SetBackdropColor(0.04, 0.04, 0.04, 0.9)
	macroFrame:SetMovable(true)
	macroFrame:EnableMouse(true)
	macroFrame:RegisterForDrag("LeftButton")
	macroFrame:SetScript("OnDragStart", macroFrame.StartMoving)
	macroFrame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local pt, _, rp, x, y = self:GetPoint()
		DB.macroPoint = { pt, rp, x, y }
	end)
	tinsert(UISpecialFrames, "KickAssistMacroFrame")

	local close = CreateFrame("Button", nil, macroFrame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)

	local title = macroFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -16)
	title:SetText("Edit Macro")

	local nameLabel = macroFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	nameLabel:SetPoint("TOPLEFT", 24, -80)
	nameLabel:SetText("Macro name:")

	local nameBox = CreateFrame("EditBox", nil, macroFrame, "InputBoxTemplate")
	nameBox:SetSize(130, 20)
	nameBox:SetPoint("LEFT", nameLabel, "RIGHT", 10, 0)
	nameBox:SetAutoFocus(false)
	nameBox:SetScript("OnEscapePressed", nameBox.ClearFocus)
	nameBox:SetScript("OnEnterPressed", nameBox.ClearFocus)
	macroFrame.nameBox = nameBox

	local note = macroFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	note:SetPoint("TOPLEFT", 24, -106)
	note:SetPoint("TOPRIGHT", -24, -106)
	note:SetJustifyH("LEFT")
	macroFrame.note = note
	note:SetText(MacroNoteText())

	local bodyLabel = macroFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	bodyLabel:SetPoint("TOPLEFT", 24, -132)
	bodyLabel:SetText("Macro body ({interrupt} and {kick} are filled in for you):")

	local scroll = CreateFrame("ScrollFrame", "KickAssistMacroScroll", macroFrame, "InputScrollFrameTemplate")
	scroll:SetSize(372, 96)
	scroll:SetPoint("TOPLEFT", 24, -152)
	scroll.EditBox:SetMultiLine(true)
	scroll.EditBox:SetMaxLetters(255)
	scroll.EditBox:SetWidth(360)
	scroll.EditBox:SetFontObject(ChatFontNormal)
	if scroll.CharCount then scroll.CharCount:Hide() end
	macroFrame.scroll = scroll

	-- Frame border around the scroll for clarity.
	local border = CreateFrame("Frame", nil, macroFrame, "BackdropTemplate")
	border:SetPoint("TOPLEFT", scroll, "TOPLEFT", -6, 6)
	border:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 22, -6)
	border:SetBackdrop({
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 12,
	})

	-- Which macro this editor is editing.
	local function CurrentName()
		local cfg = SLOT_CFG[editorSlot]
		local n = DB[cfg.nameKey]
		return (n and n ~= "") and n or cfg.defName
	end
	local function CurrentTemplate()
		local cfg = SLOT_CFG[editorSlot]
		return DB[cfg.tmplKey] or cfg.defBody
	end
	local markerBtn  -- created below; only shown for the kick/focus slots (Tab Kick has no marker)
	local function ReloadFields()
		nameBox:SetText(CurrentName())
		nameBox:SetCursorPosition(0)
		scroll.EditBox:SetText(CurrentTemplate())
		scroll.EditBox:SetCursorPosition(0)
		scroll:SetVerticalScroll(0)
		if markerBtn then markerBtn:SetShown(editorSlot == "kick" or editorSlot == "focus") end
	end
	local function ApplySlot(name, template)
		local cfg = SLOT_CFG[editorSlot]
		DB[cfg.nameKey] = name
		DB[cfg.tmplKey] = template
		if editorSlot == "kick" then
			DB.macroEnabled = true
			UpdateManagedMacro()
		elseif editorSlot == "focus" then
			UpdateSetFocusMacro(true)
		else
			UpdateAutoTabMacro(true)
		end
	end
	macroFrame.ReloadFields = ReloadFields

	-- Slot selector: pick which macro to edit.
	local editLabel = macroFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	editLabel:SetPoint("TOPLEFT", 24, -50)
	editLabel:SetText("Editing:")

	local slotDrop = CreateFrame("DropdownButton", nil, macroFrame, "WowStyle1DropdownTemplate")
	slotDrop:SetSize(160, 22)
	slotDrop:SetPoint("LEFT", editLabel, "RIGHT", 10, 0)
	local function SlotIsSelected(sk) return editorSlot == sk end
	local function SlotSetSelected(sk) editorSlot = sk; C_Timer.After(0, ReloadFields) end
	slotDrop:SetupMenu(function(dropdown, root)
		for _, key in ipairs(SLOT_ORDER) do
			root:CreateRadio(SLOT_CFG[key].label, SlotIsSelected, SlotSetSelected, key)
		end
	end)

	-- Pick an existing macro to load it. Built as a plain ScrollFrame + buttons rather
	-- than a WowStyle1Dropdown: the dropdown's ScrollBox compares a secret content
	-- extent inside instances and throws under our taint. A plain ScrollFrame (same
	-- tech as the body editor) is taint-safe, so the editor stays usable in dungeons.
	local pickBtn = CreateFrame("Button", nil, macroFrame, "UIPanelButtonTemplate")
	pickBtn:SetSize(150, 22)
	pickBtn:SetPoint("LEFT", nameBox, "RIGHT", 12, 0)
	pickBtn:SetText("Import Existing")

	local pickPanel = CreateFrame("Frame", nil, pickBtn, "BackdropTemplate")
	pickPanel:SetSize(196, 210)
	pickPanel:SetPoint("TOPLEFT", pickBtn, "BOTTOMLEFT", 0, -2)
	pickPanel:SetFrameStrata("FULLSCREEN_DIALOG")
	pickPanel:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	pickPanel:SetBackdropColor(0.05, 0.05, 0.05, 0.97)
	pickPanel:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
	pickPanel:Hide()

	local pickScroll = CreateFrame("ScrollFrame", nil, pickPanel)
	pickScroll:SetPoint("TOPLEFT", 6, -6)
	pickScroll:SetPoint("BOTTOMRIGHT", -6, 6)
	pickScroll:EnableMouseWheel(true)
	local pickChild = CreateFrame("Frame", nil, pickScroll)
	pickChild:SetSize(180, 10)
	pickScroll:SetScrollChild(pickChild)
	pickScroll:SetScript("OnMouseWheel", function(self, delta)
		local maxScroll = math.max(0, pickChild:GetHeight() - self:GetHeight())
		self:SetVerticalScroll(math.min(maxScroll, math.max(0, self:GetVerticalScroll() - delta * 36)))
	end)

	local pickRows = {}
	local function PopulatePicker()
		for _, r in ipairs(pickRows) do r:Hide() end
		local count = 0
		local function AddRow(actualIndex)
			local mname = GetMacroInfo(actualIndex)
			if not mname or mname == "" then return end
			count = count + 1
			local r = pickRows[count]
			if not r then
				r = CreateFrame("Button", nil, pickChild)
				r:SetHeight(18)
				r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
				r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
				r.text:SetPoint("LEFT", 6, 0)
				r.text:SetPoint("RIGHT", -4, 0)
				r.text:SetJustifyH("LEFT")
				pickRows[count] = r
			end
			r:SetPoint("TOPLEFT", pickChild, "TOPLEFT", 0, -(count - 1) * 18)
			r:SetPoint("TOPRIGHT", pickChild, "TOPRIGHT", 0, -(count - 1) * 18)
			r.text:SetText(mname)
			r._idx = actualIndex
			r:SetScript("OnClick", function(self)
				-- Import the BODY only into the slot you're editing. The addon keeps
				-- managing its own macro (the name above is unchanged) -- picking copies
				-- commands in as a starting point, it does NOT repoint to this macro.
				local _, _, body = GetMacroInfo(self._idx)
				scroll.EditBox:SetText(body or "")
				scroll.EditBox:SetCursorPosition(0)
				scroll:SetVerticalScroll(0)
				pickPanel:Hide()
			end)
			r:Show()
		end
		local numAccount, numChar = GetNumMacros()
		for i = 1, numAccount do AddRow(i) end
		for i = 1, numChar do AddRow(MAX_ACCOUNT_MACROS + i) end
		pickChild:SetHeight(math.max(1, count * 18))
		pickScroll:SetVerticalScroll(0)
	end

	pickBtn:SetScript("OnClick", function()
		if pickPanel:IsShown() then
			pickPanel:Hide()
		else
			PopulatePicker()
			pickPanel:Show()
			pickPanel:Raise()
		end
	end)

	local info = macroFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	info:SetPoint("TOPLEFT", 24, -256)
	info:SetPoint("TOPRIGHT", -24, -256)
	info:SetJustifyH("LEFT")
	info:SetText("Import Existing copies a macro's commands in as a starting point; Save writes them to the macro named above (the addon's own). For Focus + Kick and Set Focus, click \"Add / Sync {kick} Marker\" first to add the marker line.")

	local saveBtn = CreateFrame("Button", nil, macroFrame, "UIPanelButtonTemplate")
	saveBtn:SetSize(170, 24)
	saveBtn:SetPoint("BOTTOMLEFT", 30, 18)
	saveBtn:SetText("Save & Update Macro")
	saveBtn:SetScript("OnClick", function()
		local nm = (nameBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
		if nm == "" then nm = CurrentName() end
		ApplySlot(nm, scroll.EditBox:GetText())
		nameBox:SetText(nm)
	end)

	-- Add or sync the {kick} marker line in the body (kick/focus slots only; shown via ReloadFields).
	markerBtn = CreateFrame("Button", nil, macroFrame, "UIPanelButtonTemplate")
	markerBtn:SetSize(210, 22)
	markerBtn:SetPoint("BOTTOM", 0, 50)
	markerBtn:SetText("Add / Sync {kick} Marker")
	markerBtn:SetScript("OnClick", function()
		scroll.EditBox:SetText(ManageMarkerInBody(scroll.EditBox:GetText()))
		scroll.EditBox:SetCursorPosition(0)
		scroll:SetVerticalScroll(0)
	end)

	local templateDrop = CreateFrame("DropdownButton", nil, macroFrame, "WowStyle1DropdownTemplate")
	templateDrop:SetSize(190, 24)
	templateDrop:SetPoint("BOTTOMRIGHT", -30, 18)
	templateDrop:SetDefaultText("Choose a template...")
	templateDrop:SetupMenu(function(dropdown, root)
		root:SetScrollMode(20 * 16)
		for _, t in ipairs(TEMPLATES[editorSlot] or {}) do
			local body = t.body
			root:CreateButton(t.name, function()
				scroll.EditBox:SetText(body)
				local nm = (nameBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
				if nm == "" then nm = CurrentName() end
				ApplySlot(nm, body)
				nameBox:SetText(nm)
			end)
		end
	end)

	local p = DB.macroPoint or DEFAULTS.macroPoint
	macroFrame:ClearAllPoints()
	macroFrame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
	macroFrame:Show()
	macroFrame:Raise()
	ReloadFields()
end

--------------------------------------------------------------------------------
-- Minimap button + Blizzard options panel
--------------------------------------------------------------------------------

local minimapBtn

local function OpenSettings()
	if settingsCategory then
		Settings.OpenToCategory(settingsCategory:GetID())
	end
end

local function UpdateMinimapShown()
	if not minimapBtn then return end
	if DB.minimap.hide then minimapBtn:Hide() else minimapBtn:Show() end
end

local function UpdateMinimapPos()
	if not minimapBtn then return end
	local angle = math.rad(DB.minimap.angle or 214)
	local r = (Minimap:GetWidth() / 2) + 5
	minimapBtn:ClearAllPoints()
	minimapBtn:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

local function CreateMinimapButton()
	if minimapBtn then return end
	local b = CreateFrame("Button", "KickAssistMinimapButton", Minimap)
	b:SetSize(31, 31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")

	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetSize(20, 20)
	bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	bg:SetPoint("TOPLEFT", 7, -5)

	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetSize(18, 18)
	icon:SetPoint("TOPLEFT", 7, -6)
	SetMarkerTexture(icon, 8) -- skull

	local overlay = b:CreateTexture(nil, "OVERLAY")
	overlay:SetSize(53, 53)
	overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	overlay:SetPoint("TOPLEFT")

	b:SetScript("OnClick", function(_, button)
		if button == "RightButton" then OpenSettings() else ShowUI() end
	end)

	-- Drag around the minimap edge; OnUpdate only runs while dragging.
	b:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local scale = Minimap:GetEffectiveScale()
			local px, py = GetCursorPosition()
			px, py = px / scale, py / scale
			DB.minimap.angle = math.deg(math.atan2(py - my, px - mx))
			UpdateMinimapPos()
		end)
	end)
	b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Kick Assist")
		GameTooltip:AddLine("Left-click: open window", 1, 1, 1)
		GameTooltip:AddLine("Right-click: options", 1, 1, 1)
		GameTooltip:AddLine("Drag: move button", 1, 1, 1)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", GameTooltip_Hide)

	minimapBtn = b
	UpdateMinimapPos()
	UpdateMinimapShown()
end

local function CreateSettingsPanel()
	if settingsCategory then return end
	local panel = CreateFrame("Frame", "KickAssistSettingsPanel")
	panel.name = "Kick Assist"

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("Kick Assist")

	local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
	desc:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
	desc:SetJustifyH("LEFT")
	desc:SetText("Pick your interrupt raid marker, announce it to the group, and keep your kick macro's marker in sync.")

	local openBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	openBtn:SetSize(220, 26)
	openBtn:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -16)
	openBtn:SetText("Open Kick Assist Window")
	openBtn:SetScript("OnClick", function() ShowUI() end)

	local macroBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	macroBtn:SetSize(220, 26)
	macroBtn:SetPoint("TOPLEFT", openBtn, "BOTTOMLEFT", 0, -8)
	macroBtn:SetText("Edit Kick Macro")
	macroBtn:SetScript("OnClick", function() KickAssist_ShowMacroEditor() end)

	local mmCB = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	mmCB:SetPoint("TOPLEFT", macroBtn, "BOTTOMLEFT", 0, -16)
	mmCB:SetChecked(not DB.minimap.hide)
	mmCB:SetScript("OnClick", function(self)
		DB.minimap.hide = not self:GetChecked()
		UpdateMinimapShown()
	end)
	local mmLabel = mmCB:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	mmLabel:SetPoint("LEFT", mmCB, "RIGHT", 2, 0)
	mmLabel:SetText("Show minimap button")

	-- Which instance types the ready-check popup/announce fires in.
	local ctxHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	ctxHeader:SetPoint("TOPLEFT", mmCB, "BOTTOMLEFT", 0, -18)
	ctxHeader:SetText("Open / announce on ready check in:")

	local anchor = ctxHeader
	for _, key in ipairs(CONTEXT_ORDER) do
		local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
		cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", (anchor == ctxHeader) and 0 or 0, (anchor == ctxHeader) and -6 or -4)
		cb:SetChecked(ContextEnabled(key))
		cb:SetScript("OnClick", function(self)
			DB.contexts = DB.contexts or {}
			DB.contexts[key] = self:GetChecked() and true or false
		end)
		local lbl = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
		lbl:SetText(CONTEXT_LABELS[key])
		anchor = cb
	end

	local category = Settings.RegisterCanvasLayoutCategory(panel, "Kick Assist")
	Settings.RegisterAddOnCategory(category)
	settingsCategory = category
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("READY_CHECK")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
ev:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON then return end
		KickAssistDB = KickAssistDB or {}
		DB = KickAssistDB
		for k, v in pairs(DEFAULTS) do
			if DB[k] == nil then
				DB[k] = (type(v) == "table") and CopyTable(v) or v
			end
		end
		CreateMinimapButton()
		CreateSettingsPanel()
		print(PREFIX .. "loaded. /ka to open.")
	elseif event == "READY_CHECK" then
		-- In an enabled instance type: pop the picker (out of combat) and, before the
		-- key locks chat, auto-announce your kick. Announce(true) self-skips once the
		-- key is active, so it never causes a blocked-action error.
		if DB and ShouldTriggerHere() then
			if DB.showOnReadyCheck then ShowUI(true) end
			if DB.announceOnReadyCheck then Announce(true) end
		end
	elseif event == "PLAYER_REGEN_ENABLED" then
		-- Catch up any macro edits deferred from combat.
		SyncMacros()
	elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
		-- New spec may have a different interrupt; re-sync both macros.
		if arg1 == "player" then
			SyncMacros()
			if macroFrame and macroFrame:IsShown() then macroFrame.note:SetText(MacroNoteText()) end
		end
	end
end)

--------------------------------------------------------------------------------
-- Slash
--------------------------------------------------------------------------------

SLASH_KICKASSIST1 = "/ka"
SLASH_KICKASSIST2 = "/kickassist"
SlashCmdList["KICKASSIST"] = function(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "hide" then
		if frame then frame:Hide() end
	elseif msg == "macro" then
		KickAssist_ShowMacroEditor()
	elseif msg == "options" or msg == "config" then
		OpenSettings()
	elseif msg == "minimap" then
		DB.minimap.hide = not DB.minimap.hide
		UpdateMinimapShown()
	elseif msg == "" or msg == "show" then
		ShowUI()
	else
		print(PREFIX .. "commands: /ka (open), /ka macro, /ka options, /ka minimap, /ka hide")
	end
end
