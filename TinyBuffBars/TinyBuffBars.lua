-- TinyBuffBars - player auras as stacked bars.
--
-- Blocks, top to bottom:
--   0. tracking               grey,   a button, not an aura - opens the menu
--   1. permanent buffs        green,  full bar, no timer
--   2. timed buffs            blue,   drains, shows remaining
--   3. debuffs                coloured by dispel type, drains
--   4. temporary weapon buffs purple, drains
--
-- Right click cancels a buff, a timed buff or a weapon buff. Debuffs cannot be
-- cancelled and tracking is handled separately, so neither registers the click.
--
-- WHY THIS IS BUILT THE WAY IT IS
--
-- As of 12.1 an addon can no longer read aura data and draw its own bars: the
-- fields of AuraData carry SecretWhenUnitAuraRestricted, so in combat, an
-- encounter, a key or a PvP match every comparison on them raises. That is what
-- killed the old bar addons.
--
-- The sanctioned replacement is CustomAuraContainer. The addon declares aura
-- groups and a frame template; the client picks which auras land in which group
-- and fills the bars with secret values itself. There is deliberately no
-- per-aura callback for us - initializeFrame runs once per created frame, and
-- AuraButton forbids UntrustedScriptExecution so no script can be attached
-- either. Everything per-aura must therefore be expressed either as group
-- membership or as one of the client's own declarative bindings.
--
-- That is the rule the whole file follows:
--   * colour per block          -> a group per block
--   * colour per dispel type    -> AddDispelTypeTexture, the client tints it
--   * right click to cancel     -> SetCancelAuraButtons, the client cancels
--   * permanent vs timed        -> group filters, see below
--
-- Block 1 is the awkward one. The only duration filter a group has is
-- maxDuration, i.e. "timed only"; there is no inverse. So block 1 is built as
-- "all buffs minus the ones we know are timed", using excludeSpellIDs.
--
-- Two facts make that reliable rather than a hack:
--   * AuraContainerUtil.CanApplyIdentityCandidateFilters short-circuits to true
--     for helpful auras on the player, so excludeSpellIDs keeps being applied
--     in combat, when everything else has gone secret.
--   * C_Secrets.ShouldUnitAuraIndexBeSecret answers with a plain boolean and
--     touches nothing secret, so we can tell exactly when a read is safe.
--
-- Whenever a read is safe we classify what we see and remember it across
-- sessions. A timed buff the addon has never once seen unrestricted shows up in
-- block 1 as well until that happens; one sighting out of combat fixes it for
-- good.
--
-- Debuffs get no such split: CanApplyIdentityCandidateFilters deliberately
-- refuses spell ID filters for harmful auras on the player, so block 3 is one
-- group holding timed and permanent debuffs together.
--
-- HOW A BAR IS PAINTED
--
-- Track is a half-transparent backing across the full width, and the fill on
-- top of it is the block colour at full opacity, shrinking with the remaining
-- time. Nothing opaque may lie under the spent part or the world would not show
-- through it, so the colour has to be the thing that shrinks rather than
-- something a dark overlay covers up.
--
-- That costs one case: a permanent aura in a mixed block. Its duration is zero,
-- the client reports that as an empty bar, and there is no per-aura hook to
-- special-case it. Block 1 sidesteps it by binding no duration at all and
-- pinning the fill full; block 3 cannot, because it holds both kinds.

local ADDON_NAME = ...

-- Bumped on every change worth telling apart in game. /tbb prints it, so
-- "is the client running what I just edited" is one command, not guesswork.
local VERSION = "3.3"

local BAR_TEMPLATE = "TinyBuffBarsBarTemplate"
local BAR_GAP      = 1   -- between bars inside a block
local BLOCK_GAP    = 6   -- between blocks
local DEFAULT_ALPHA = 0.5 -- the backing behind a bar; the bar itself is opaque

local DEFAULT_WIDTH  = 220
local DEFAULT_HEIGHT = 16

-- Bar sizes are read once on load. Frames are created by the client in batches
-- and configured only in initializeFrame, so a size change needs a reload.
local barWidth, barHeight, barAlpha

-- Flat on purpose. The previous fallback, Interface\TargetingFrame\UI-StatusBar,
-- is a bevelled texture whose lighter top edge reads as a border on a bar this
-- thin. WHITE8X8 is a single flat pixel, so the bar gets no edges at all, which
-- is also how ElvUI Norm looks when it is available.
local FALLBACK_TEXTURE = [[Interface\Buttons\WHITE8X8]]
local ELVUI_MEDIA_TEXTURE = [[Interface\AddOns\ElvUI-media\media\textures\normTex2.tga]]

local barTexture = FALLBACK_TEXTURE

-- Blizzard caps the player's buff and debuff lists well below this.
local MAX_AURA_INDEX = 40

local COLOR = {
	tracking  = { 1.00, 0.68, 0.30 },
	permanent = { 0.16, 0.70, 0.24 },
	timed     = { 0.18, 0.44, 0.88 },
	debuff    = { 0.78, 0.18, 0.18 },
	weapon    = { 0.60, 0.30, 0.85 },
}

-- Applied by the client, not by us: the bar's fill is registered as a dispel
-- type texture and tinted from this map. "None" covers everything without a
-- dispel type, which is where bleeds and other physical debuffs land - the
-- client exposes no finer distinction than dispelName.
local DISPEL_COLOR = {
	Magic   = { 0.20, 0.45, 0.90 },
	Curse   = { 0.60, 0.25, 0.85 },
	Disease = { 0.60, 0.45, 0.15 },
	Poison  = { 0.20, 0.65, 0.25 },
	None    = { 0.78, 0.18, 0.18 },
}

local anchor, handle, container, trackingButton
local timedSpells = {}
local durationFormatter
local enchantFrames = {}
local tooltipAnchor = "ANCHOR_RIGHT"

-- Every aura group key, in the order they are registered. Used to walk the
-- frames the container owns when the tooltip side changes.
local AURA_GROUPS = { "permanent", "timed", "debuff" }

-- Blizzard's default aura formatter caps at one unit and clamps the largest
-- interval to minutes, so 75 minutes reads as "75m". Two units and an uncapped
-- interval give "1h 15m" instead.
local function CreateDurationFormatter()
	local formatter = C_StringUtil.CreateSecondsFormatter()

	formatter:SetDefaultAbbreviation(Enum.SecondsFormatterAbbreviation.OneLetter)
	formatter:SetRounding(Enum.SecondsFormatterRounding.Truncate)

	-- Both of these exist to stop "1h 60m". CanRoundUpLastUnit rounds the final
	-- unit up without carrying into the one above it, so 1:59:59 became 1 hour
	-- plus 59.99 minutes rounded to 60. Truncating instead gives 1h 59m.
	-- CanRoundUpIntervals is the carry Blizzard document as "60m -> 1h", kept
	-- on so no other path can produce that shape either.
	formatter:SetCanRoundUpLastUnit(false)
	formatter:SetCanRoundUpIntervals(true)
	formatter:SetMinInterval(Enum.SecondsFormatterInterval.Seconds)
	formatter:SetMaxInterval(Enum.SecondsFormatterInterval.Days)
	formatter:SetDesiredUnitCount(2)

	return formatter
end

-- Blizzard's own buff display is an Edit Mode system, so Hide() does not stick -
-- the manager shows it again. Reparenting to a frame that is never shown keeps
-- it away without fighting anything, and putting it back is the same call.
-- Events are left registered on purpose: the frame costs almost nothing while
-- invisible, and this way restoring it needs no repair. Temporary weapon
-- enchants live inside BuffFrame, so they go with it.
local hiddenParent

local function SetBlizzardAurasShown(shown)
	if not hiddenParent then
		hiddenParent = CreateFrame("Frame")
		hiddenParent:Hide()
	end

	local parent = shown and UIParent or hiddenParent

	if BuffFrame then
		BuffFrame:SetParent(parent)
	end

	if DebuffFrame then
		DebuffFrame:SetParent(parent)
	end
end

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cFF3FA9F5TinyBuffBars|r: " .. msg)
end

-- "ElvUI Norm" if it is installed, the Blizzard bar otherwise. LibSharedMedia
-- is asked first because it knows the path for both ElvUI proper and the
-- standalone ElvUI-media library; the direct path is the fallback for when the
-- media addon is present without the lib.
local function ResolveBarTexture()
	if LibStub then
		local lsm = LibStub("LibSharedMedia-3.0", true)
		if lsm then
			local path = lsm:Fetch("statusbar", "ElvUI Norm", true)
			if path then
				return path
			end
		end
	end

	if C_AddOns.IsAddOnLoaded("ElvUI-media") then
		return ELVUI_MEDIA_TEXTURE
	end

	return FALLBACK_TEXTURE
end

-- Tracking ------------------------------------------------------------------

-- Tracking is not an aura. The five spell-type entries C_Minimap reports put no
-- buff on the player, which is why an aura group filtered to their spell IDs
-- stayed empty. So this is simply Blizzard's minimap tracking button duplicated
-- as the top row: a button of ours, with none of the aura container's
-- restrictions on it.
--
-- The excludes table is securecopied on the way in, so a fresh one is handed
-- over every time rather than mutated in place.
local function PermanentExcludes()
	local excludes = {}

	for spellID in pairs(timedSpells) do
		excludes[spellID] = true
	end

	return excludes
end

-- Tooltips open away from the screen edge the bars sit against: bars on the
-- left half get their tooltip on the right, and the other way round. The side
-- is decided from the anchor, which is our own frame and carries no secret
-- values - the container's own size and the bars' positions do, and are never
-- read here.
local function ComputeTooltipAnchor()
	local left = anchor and anchor:GetLeft()
	local screenWidth = UIParent:GetWidth()

	if not left or not screenWidth or screenWidth == 0 then
		return "ANCHOR_RIGHT"
	end

	if (left + barWidth / 2) < (screenWidth / 2) then
		return "ANCHOR_RIGHT"
	end

	return "ANCHOR_LEFT"
end

-- Push the current side onto every frame already built. New frames pick it up
-- in initializeFrame instead, because the client creates them in batches
-- whenever it feels like it.
local function ApplyTooltipAnchor()
	local wanted = ComputeTooltipAnchor()
	tooltipAnchor = wanted

	if not container then return end

	-- Aura frames are access-restricted once auras go secret, so touching them
	-- then would be refused. The side only changes when the bars are dragged,
	-- which is not something that happens mid-encounter.
	if C_Secrets.ShouldAurasBeSecret() then return end

	for _, groupKey in ipairs(AURA_GROUPS) do
		for i = 1, container:GetAuraGroupFrameCount(groupKey) do
			local frame = container:GetAuraGroupFrame(groupKey, i)
			if frame then
				frame:SetTooltipAnchorPoint(wanted)
			end
		end
	end

	for _, frame in ipairs(enchantFrames) do
		frame:SetTooltipAnchorPoint(wanted)
	end
end

-- Names and icon of whatever spell tracking is switched on right now. Only
-- spell-type entries count: the other twenty-odd are map filters like vendors
-- and points of interest, which are "active" almost always and say nothing.
local function GetActiveTracking()
	local names, icon = {}, nil

	for i = 1, C_Minimap.GetNumTrackingTypes() do
		local info = C_Minimap.GetTrackingInfo(i)
		if info and info.spellID and info.active then
			table.insert(names, info.name)
			icon = icon or info.texture
		end
	end

	return names, icon
end

-- Blizzard keep the tracking menu as a closure on their own dropdown button and
-- export no opener, so the generator is borrowed from it and re-hosted on our
-- frame. Reading that field is the fragile part; everything else is public.
local function OpenTrackingMenu(owner)
	local button = MinimapCluster and MinimapCluster.Tracking and MinimapCluster.Tracking.Button
	local generator = button and button.menuGenerator

	if not generator then
		Print("tracking menu not found, open it on the minimap first.")
		return
	end

	MenuUtil.CreateContextMenu(owner, generator)
end

-- Frame setup ---------------------------------------------------------------

-- Returns the initializeFrame callback for one block. The client calls it once
-- per frame it creates, before it applies its own access restrictions, so this
-- is the only chance to wire anything up.
--
-- spec.color        key into COLOR, ignored when dispelColored
-- spec.timer        bind the bar and the text to the aura's duration
-- spec.cancel       right click cancels the aura
-- spec.dispelColored  let the client tint the track by dispel type
local function MakeInitializer(spec)
	local r, g, b = unpack(COLOR[spec.color])

	return function(frame)
		frame:SetSize(barWidth, barHeight)

		-- Track holds the colour across the whole bar; the fill on top of it is
		-- the dark part that eats the colour as time runs out. Reverse fill
		-- makes it grow from the right, so what is left of the colour shrinks
		-- left to right like an ordinary countdown bar.
		-- Back is the backing: the block colour at barAlpha, full width, and the
		-- only thing left where the bar has run down, so the world shows through
		-- there. Bar on top of it is the same colour at full opacity, shrinking
		-- with the remaining time. Text sits over both.
		--
		-- The alpha lives on the Back FRAME, never on its texture: a texture's
		-- SetAlpha is overridden by the alpha of any later SetVertexColor, and
		-- one always follows - ours below, or the client's on the dispel block.
		local level = frame.Bar:GetFrameLevel()
		frame.Back:SetFrameLevel(level)
		frame.Bar:SetFrameLevel(level + 5)
		frame.Text:SetFrameLevel(level + 10)

		frame.Back:SetAlpha(barAlpha)
		frame.Back.Track:SetTexture(barTexture)
		frame.Bar.Fill:SetTexture(barTexture)

		-- The StatusBar itself paints nothing. It is driven by elapsed time with
		-- reverse fill purely so its texture's left edge marks where the
		-- remaining time ends, and Fill is stretched to that edge. See the
		-- template header for why the colour is not simply the bar's own fill.
		frame.Bar:SetStatusBarTexture(barTexture)
		frame.Bar:SetStatusBarColor(1, 1, 1, 0)
		frame.Bar:SetReverseFill(true)
		frame.Bar:SetMinMaxValues(0, 1)

		frame.Bar.Fill:ClearAllPoints()

		if spec.timer then
			frame.Bar.Fill:SetPoint("TOPLEFT", frame.Bar, "TOPLEFT")
			frame.Bar.Fill:SetPoint("BOTTOMRIGHT", frame.Bar:GetStatusBarTexture(), "BOTTOMLEFT")
		else
			-- Nothing drives this block, so the colour just spans the bar.
			frame.Bar.Fill:SetAllPoints(frame.Bar)
		end

		if spec.dispelColored then
			local colorMap = {}
			for dispelName, rgb in pairs(DISPEL_COLOR) do
				colorMap[dispelName] = CreateColor(rgb[1], rgb[2], rgb[3])
			end

			local dispelOptions = {
				showAlways = true,
				showWithoutDispelType = true,
				style = Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset,
				customDispelColorMap = colorMap,
			}

			-- Fill and backing are both handed over so the client tints them
			-- together from dispelName, a secret value we never see ourselves.
			-- PreserveAsset keeps the texture and only recolours it. The status
			-- bar's own texture stays out of this: it is invisible by design.
			frame:AddDispelTypeTexture(frame.Bar.Fill, dispelOptions)
			frame:AddDispelTypeTexture(frame.Back.Track, dispelOptions)
		else
			frame.Bar.Fill:SetVertexColor(r, g, b, 1)
			frame.Back.Track:SetVertexColor(r, g, b, 1)
		end

		-- Icon and name are filled by the client from secret data.
		frame:SetIcon(frame.Icon)
		frame:SetSpellName(frame.Text.Name)
		frame:SetTooltipAnchorPoint(tooltipAnchor)

		if spec.cancel then
			-- The token has to carry Down or Up: CanCancelAuraOnClick builds it
			-- as button .. ("Down" or "Up"), so a bare "RightButton" matches
			-- nothing and silently does nothing.
			frame:SetCancelAuraButtons("RightButtonUp")
		end

		if spec.timer then
			frame:SetDurationBar(frame.Bar, {
				direction = Enum.StatusBarTimerDirection.ElapsedTime,
				interpolation = Enum.StatusBarInterpolation.Immediate,
			})
			frame:SetDurationText(frame.Text.Time, { textFormatter = durationFormatter })
		else
			frame.Text.Time:SetText("")
		end
	end
end

local function BlockLayout(index, gap)
	return {
		layoutIndex = index,
		elementSpacing = BAR_GAP,
		groupSpacing = gap or BLOCK_GAP,
		elementWidth = barWidth,
		elementHeight = barHeight,
	}
end

-- The anchor holds the position and never takes the mouse, so it can never
-- swallow a click meant for a bar. Dragging happens on a separate handle.
--
-- The handle lies on top of the top row rather than above it, so showing and
-- hiding it moves nothing: what you line up while unlocked is exactly where the
-- bars stay after /tbb lock. That means it has to out-rank the frames beneath
-- it for the mouse, hence the explicit frame level.
--
-- It anchors to the anchor rather than to the container on purpose: once a
-- group is added the container carries UntrustedLayoutScriptExecution and
-- anchoring addon frames against it is refused. Its size is a secret value
-- besides, so nothing here may read it.
local function BuildAnchor()
	anchor = CreateFrame("Frame", "TinyBuffBarsAnchor", UIParent)
	anchor:SetSize(barWidth, barHeight)
	anchor:SetMovable(true)

	local pos = TinyBuffBarsDB.pos
	if pos then
		anchor:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
	else
		anchor:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
	end

	handle = CreateFrame("Frame", nil, anchor)
	handle:SetSize(barWidth, barHeight)
	handle:SetPoint("TOPLEFT", anchor, "TOPLEFT")
	handle:SetFrameLevel(anchor:GetFrameLevel() + 30)
	handle:EnableMouse(true)
	handle:RegisterForDrag("LeftButton")
	handle:Hide()

	local bg = handle:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.10, 0.45, 0.80, 0.85)

	local label = handle:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	label:SetPoint("CENTER")
	label:SetText("drag me, then /tbb lock")

	handle:SetScript("OnDragStart", function() anchor:StartMoving() end)
	handle:SetScript("OnDragStop", function()
		anchor:StopMovingOrSizing()
		local point, _, relPoint, x, y = anchor:GetPoint()
		TinyBuffBarsDB.pos = { point = point, relPoint = relPoint, x = x, y = y }
		ApplyTooltipAnchor()
	end)
end

-- The minimap tracking button, duplicated as the top row and styled like a bar.
-- Built by hand rather than from BAR_TEMPLATE: that template only makes sense
-- attached to an aura, and this frame is ours outright, so it can take scripts
-- and clicks that an AuraButton forbids. ICON_INSET matches the template so the
-- text lines up with the rows below.
local ICON_INSET = 16
local ICON_SIZE = 14

local function BuildTrackingButton()
	trackingButton = CreateFrame("Button", nil, anchor)
	trackingButton:SetSize(barWidth, barHeight)
	trackingButton:SetPoint("TOPLEFT", anchor, "TOPLEFT")
	trackingButton:RegisterForClicks("AnyUp")

	-- One opaque texture, no backing frame and no alpha. This row never runs
	-- down, so there is no spent part for a backing to show through, and a
	-- permanent aura's bar is opaque too - this matches it.
	--
	-- It also has to be a layer of the button rather than a child frame: a
	-- child frame draws above its parent's layers, so a backing frame here
	-- covered the label and made the white text read as grey through it.
	local track = trackingButton:CreateTexture(nil, "BACKGROUND")
	track:SetPoint("TOPLEFT", ICON_INSET, 0)
	track:SetPoint("BOTTOMRIGHT", 0, 0)
	track:SetTexture(barTexture)
	track:SetVertexColor(COLOR.tracking[1], COLOR.tracking[2], COLOR.tracking[3], 1)

	local icon = trackingButton:CreateTexture(nil, "ARTWORK")
	icon:SetSize(ICON_SIZE, ICON_SIZE)
	icon:SetPoint("LEFT", 1, 0)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	trackingButton.Icon = icon

	local label = trackingButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	label:SetPoint("LEFT", track, "LEFT", 3, 0)
	label:SetPoint("RIGHT", track, "RIGHT", -3, 0)
	label:SetJustifyH("LEFT")
	label:SetWordWrap(false)
	-- Set explicitly rather than left to the font: the inherited colour is not
	-- guaranteed to stay white across font changes.
	label:SetTextColor(1, 1, 1)
	trackingButton.Label = label

	trackingButton:SetScript("OnClick", function(self)
		OpenTrackingMenu(self)
	end)

	-- The aura bars get their tooltip from the client; this one is ours to
	-- fill, and it uses the same screen-side anchor the bars do.
	trackingButton:SetScript("OnEnter", function(self)
		local names = GetActiveTracking()

		GameTooltip:SetOwner(self, tooltipAnchor)
		GameTooltip:AddLine("Tracking")

		if #names > 0 then
			for _, name in ipairs(names) do
				GameTooltip:AddLine(name, 1, 1, 1)
			end
		else
			GameTooltip:AddLine("nothing tracked", 0.6, 0.6, 0.6)
		end

		GameTooltip:AddLine("Click for tracking options", 0.4, 0.75, 1)
		GameTooltip:Show()
	end)

	trackingButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
end

local function UpdateTrackingButton()
	local names, icon = GetActiveTracking()

	trackingButton.Icon:SetTexture(icon or [[Interface\Minimap\Tracking\None]])
	trackingButton.Label:SetText(#names > 0 and table.concat(names, ", ") or "Tracking")
end

-- An aura button does not stop the 3D world underneath from being hovered, so
-- a unit behind the bars pops its own tooltip alongside the aura's. Our own
-- frames do block it, so one mouse-enabled frame the exact size of the
-- container fixes it.
--
-- Anchoring to the container needs DisableUntrustedLayoutScriptsTemplate:
-- AddAuraGroup stamps UntrustedLayoutScriptExecution onto the container, and
-- that template is Blizzard's opt-in for frames that still want to attach. The
-- container's size is a secret value, which is exactly why this is anchored to
-- it rather than measured. It sits below the aura buttons so their tooltips
-- still win.
local function BuildMouseBlocker(parent)
	local blocker = CreateFrame("Frame", nil, parent, "DisableUntrustedLayoutScriptsTemplate")
	blocker:SetAllPoints(container)
	blocker:SetFrameLevel(container:GetFrameLevel())
	blocker:EnableMouse(true)
	return blocker
end

local function BuildContainer()
	container = CreateFrame("AuraContainer", "TinyBuffBarsContainer", anchor, "CustomAuraContainerTemplate")

	-- Anchor the container before any group is added: AddAuraGroup stamps
	-- UntrustedLayoutScriptExecution onto it, after which addon-side anchoring
	-- against it is refused. It hangs under the tracking button, which is the
	-- top row and is not an aura.
	container:SetPoint("TOPLEFT", trackingButton, "BOTTOMLEFT", 0, -BAR_GAP)
	container:SetUnit("player")

	container:SetFlowLayoutAxis(AnchorUtil.FlowLayoutAxis.Vertical)
	container:SetFlowLayoutAnchorPoint("TOPLEFT")
	container:SetFlowLayoutGrowthDirection(AnchorUtil.FlowDirection.Right, AnchorUtil.FlowDirection.Down)

	-- 1. Permanent buffs: everything helpful except tracking and what we have
	-- learned is timed. No gap, they read as one block with tracking.
	container:AddAuraGroup("permanent", "HELPFUL", {
		templateNames = { BAR_TEMPLATE },
		initializeFrame = MakeInitializer({ color = "permanent", cancel = true }),
		candidateFilters = { excludeSpellIDs = PermanentExcludes() },
		sortMethod = AuraContainerSortMethod.NameOnly,
		sortDirection = AuraContainerSortDirection.Normal,
		layout = BlockLayout(1, 0),
	})

	-- 2. Timed buffs. maxDuration also drops permanent auras, which is exactly
	-- the half of the split the API does hand us.
	container:AddAuraGroup("timed", "HELPFUL", {
		templateNames = { BAR_TEMPLATE },
		initializeFrame = MakeInitializer({ color = "timed", timer = true, cancel = true }),
		candidateFilters = { maxDuration = math.huge },
		sortMethod = AuraContainerSortMethod.ExpirationOnly,
		sortDirection = AuraContainerSortDirection.Reverse,
		layout = BlockLayout(2),
	})

	-- 3. Debuffs, timed and permanent in one group. They cannot be split - the
	-- API has no "permanent only" filter and refuses spell ID filters for
	-- harmful auras on the player - but the edge-anchored fill renders both
	-- correctly from the same setup, so they do not need to be.
	container:AddAuraGroup("debuff", "HARMFUL", {
		templateNames = { BAR_TEMPLATE },
		initializeFrame = MakeInitializer({ color = "debuff", timer = true, dispelColored = true }),
		sortMethod = AuraContainerSortMethod.ExpirationOnly,
		sortDirection = AuraContainerSortDirection.Reverse,
		layout = BlockLayout(3),
	})

	-- 4. Temporary weapon buffs. hidePermanent drops the ordinary permanent
	-- enchant on the weapon and leaves poisons, stones and imbues.
	container:SetItemEnchantmentSortMethod(
		AuraContainerItemEnchantmentSortMethod.Duration, AuraContainerSortDirection.Reverse)
	container:SetItemEnchantmentLayout(BlockLayout(4))

	local enchantSlots = {
		AuraContainerItemEnchantmentSlot.MainHand,
		AuraContainerItemEnchantmentSlot.OffHand,
		AuraContainerItemEnchantmentSlot.Ranged,
	}

	for _, slot in ipairs(enchantSlots) do
		-- Item enchantment frames live outside the aura groups, so the only
		-- handle on them is the one AddItemEnchantment hands back.
		local frame = container:AddItemEnchantment(slot, {
			templateNames = { BAR_TEMPLATE },
			initializeFrame = MakeInitializer({ color = "weapon", timer = true, cancel = true }),
			hidePermanent = true,
		})

		table.insert(enchantFrames, frame)
	end
end

-- Classification ------------------------------------------------------------

-- Record which buff spells carry a duration, so block 1 can exclude them.
-- Only ever reads indices the client says are safe to read.
local function Classify()
	-- Under restrictions nearly every index is secret; the handful of spells
	-- flagged NeverSecret are not worth 40 queries a frame in combat, and they
	-- get picked up the moment restrictions lift.
	if C_Secrets.ShouldAurasBeSecret() then return end

	local changed = false

	for i = 1, MAX_AURA_INDEX do
		if not C_Secrets.ShouldUnitAuraIndexBeSecret("player", i, "HELPFUL") then
			local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
			if not aura then
				-- Readable and empty means the list ended here.
				break
			end

			local spellID = aura.spellId
			if spellID and aura.duration and aura.duration > 0 and not timedSpells[spellID] then
				timedSpells[spellID] = true
				changed = true
			end
		end
	end

	if changed then
		container:SetAuraGroupCandidateFilters("permanent", { excludeSpellIDs = PermanentExcludes() })
	end
end

-- Slash command -------------------------------------------------------------

local function SetLocked(locked)
	TinyBuffBarsDB.locked = locked
	handle:SetShown(not locked)
	Print(locked and "locked." or "drag the blue handle at the top.")
end

SLASH_TINYBUFFBARS1 = "/tbb"
SlashCmdList.TINYBUFFBARS = function(msg)
	local rest
	msg, rest = msg:lower():match("^%s*(%S*)%s*(.-)%s*$")

	if msg == "unlock" then
		SetLocked(false)
	elseif msg == "lock" then
		SetLocked(true)
	elseif msg == "reset" then
		TinyBuffBarsDB.pos = nil
		anchor:ClearAllPoints()
		anchor:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
		ApplyTooltipAnchor()
		Print("position reset to the centre of the screen.")
	elseif msg == "width" or msg == "height" then
		local value = tonumber(rest)
		if not value or value < 8 or value > 600 then
			Print(("%s is %d. Give it a number: /tbb %s 300")
				:format(msg, msg == "width" and barWidth or barHeight, msg))
			return
		end

		TinyBuffBarsDB[msg] = math.floor(value)
		Print(("%s = %d, applies after /reload.")
			:format(msg, TinyBuffBarsDB[msg]))
	elseif msg == "alpha" then
		local value = tonumber(rest)
		if not value or value < 0 or value > 1 then
			Print(("backing alpha is %.2f. Give it 0 to 1: /tbb alpha 0.35")
				:format(barAlpha))
			return
		end

		barAlpha = value
		TinyBuffBarsDB.alpha = value


		-- Applied straight away rather than on reload: it is only the backing
		-- texture, and those can be walked. Aura frames are access-restricted
		-- once auras go secret, so in that state it waits for the reload.
		if C_Secrets.ShouldAurasBeSecret() then
			Print(("backing alpha = %.2f, applies after combat or /reload."):format(value))
			return
		end

		for _, groupKey in ipairs(AURA_GROUPS) do
			for i = 1, container:GetAuraGroupFrameCount(groupKey) do
				local frame = container:GetAuraGroupFrame(groupKey, i)
				if frame then
					frame.Back:SetAlpha(value)
				end
			end
		end

		for _, frame in ipairs(enchantFrames) do
			frame.Back:SetAlpha(value)
		end

		Print(("backing alpha = %.2f"):format(value))
	elseif msg == "blizz" then
		TinyBuffBarsDB.hideBlizzard = not TinyBuffBarsDB.hideBlizzard
		SetBlizzardAurasShown(not TinyBuffBarsDB.hideBlizzard)
		Print(TinyBuffBarsDB.hideBlizzard
			and "Blizzard buff and debuff frames hidden."
			or "Blizzard buff and debuff frames restored.")
	elseif msg == "track" then
		-- What the client itself reports as tracking, plus whether the minimap
		-- menu we borrow is reachable.
		local types = C_Minimap.GetNumTrackingTypes()
		Print(("tracking types: %d"):format(types))

		for i = 1, types do
			local info = C_Minimap.GetTrackingInfo(i)
			if info and info.spellID then
				Print(("  [%d] %s - spellID %d, type %s%s")
					:format(i, info.name or "?", info.spellID, tostring(info.type),
						info.active and ", |cFF40FF40active|r" or ""))
			end
		end

		local names = GetActiveTracking()
		Print(("active now: %d%s")
			:format(#names, #names > 0 and " — " .. table.concat(names, ", ") or ""))

		local button = MinimapCluster and MinimapCluster.Tracking and MinimapCluster.Tracking.Button
		Print(("minimap menu: %s"):format(
			(button and button.menuGenerator) and "|cFF40FF40found|r" or "|cFFFF6060NOT found|r"))
	elseif msg == "forget" then
		wipe(timedSpells)
		container:SetAuraGroupCandidateFilters("permanent", { excludeSpellIDs = PermanentExcludes() })
		Print("learned timed buffs cleared, they will be picked up again.")
	else
		local learned = 0
		for _ in pairs(timedSpells) do
			learned = learned + 1
		end

		Print(("version %s, %s"):format(VERSION,
			TinyBuffBarsDB.locked and "|cFFFF6060locked|r - /tbb unlock to move it" or "unlocked"))
		Print("/tbb unlock | lock | reset | forget | track | blizz | width N | height N | alpha N")
		Print(("bar %dx%d, backing alpha %.2f, texture %s")
			:format(barWidth, barHeight, barAlpha,
				barTexture == FALLBACK_TEXTURE and "default" or "ElvUI Norm"))
		Print(("timed buffs learned: %d, blizzard frames %s")
			:format(learned, TinyBuffBarsDB.hideBlizzard and "hidden" or "shown"))
	end
end

-- Events --------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON_NAME then return end
		self:UnregisterEvent("ADDON_LOADED")

		TinyBuffBarsDB = TinyBuffBarsDB or {}
		TinyBuffBarsDB.timedSpells = TinyBuffBarsDB.timedSpells or {}
		timedSpells = TinyBuffBarsDB.timedSpells

		barWidth = TinyBuffBarsDB.width or DEFAULT_WIDTH
		barHeight = TinyBuffBarsDB.height or DEFAULT_HEIGHT
		barAlpha = TinyBuffBarsDB.alpha or DEFAULT_ALPHA
		barTexture = ResolveBarTexture()
		durationFormatter = CreateDurationFormatter()

		-- Unlocked on a fresh install: the drag handle sits above the bars
		-- rather than over them, so there is nothing for it to get in the way
		-- of, and an invisible unmovable frame is worse than a visible one.
		if TinyBuffBarsDB.locked == nil then
			TinyBuffBarsDB.locked = false
		end

		-- Hidden by default: the whole point of the addon is to replace them.
		if TinyBuffBarsDB.hideBlizzard == nil then
			TinyBuffBarsDB.hideBlizzard = true
		end

		SetBlizzardAurasShown(not TinyBuffBarsDB.hideBlizzard)

		BuildAnchor()
		tooltipAnchor = ComputeTooltipAnchor()
		BuildTrackingButton()
		BuildContainer()
		BuildMouseBlocker(anchor)
		UpdateTrackingButton()

		handle:SetShown(not TinyBuffBarsDB.locked)

		self:RegisterEvent("PLAYER_ENTERING_WORLD")
		self:RegisterEvent("PLAYER_REGEN_ENABLED")
		self:RegisterEvent("MINIMAP_UPDATE_TRACKING")
		self:RegisterEvent("SPELLS_CHANGED")
		self:RegisterUnitEvent("UNIT_AURA", "player")
	elseif event == "MINIMAP_UPDATE_TRACKING" or event == "SPELLS_CHANGED"
		or event == "PLAYER_ENTERING_WORLD" then
		UpdateTrackingButton()
		ApplyTooltipAnchor()
		SetBlizzardAurasShown(not TinyBuffBarsDB.hideBlizzard)
		Classify()
	else
		Classify()
	end
end)
