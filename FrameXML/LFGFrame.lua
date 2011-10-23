-----
--A note on nomenclature:
--LFD is used for Dungeon-specific functions and values
--LFR is used for Raid-specific functions and values
--LFG is used for for generic functions/values that may be used for LFD, LFR, and any other LF_ system we may implement in the future.
------

--DEBUG FIXME:
function LFGDebug(text, ...)
	if ( GetCVarBool("lfgDebug") ) then
		ConsolePrint("LFGLua: "..format(text, ...));
	end
end

LFG_ID_TO_ROLES = { "DAMAGER", "TANK", "HEALER" };
LFG_RETURN_VALUES = {
	name = 1,
	typeID = 2,
	minLevel = 3,
	maxLevel = 4,
	recLevel = 5,	--Recommended level
	minRecLevel = 6,	--Minimum recommended level
	maxRecLevel = 7,	--Maximum recommended level
	expansionLevel = 8,
	groupID = 9,
	texture = 10,
	difficulty = 11,
	maxPlayers = 12,
}

LFG_INSTANCE_INVALID_RAID_LOCKED = 6;

LFG_INSTANCE_INVALID_CODES = { --Any other codes are unspecified conditions (e.g. attunements)
	"EXPANSION_TOO_LOW",
	"LEVEL_TOO_LOW",
	"LEVEL_TOO_HIGH",
	"GEAR_TOO_LOW",
	"GEAR_TOO_HIGH",
	"RAID_LOCKED",
	nil,	--Target level too high
	nil,	--Target level too low
	"AREA_NOT_EXPLORED",
	[1001] = "LEVEL_TOO_LOW",
	[1002] = "LEVEL_TOO_HIGH",
	[1022] = "QUEST_NOT_COMPLETED",
	[1025] = "MISSING_ITEM",
	
}

LFG_ROLE_SHORTAGE_RARE = 1;
LFG_ROLE_SHORTAGE_UNCOMMON = 2;
LFG_ROLE_SHORTAGE_PLENTIFUL = 3;
LFG_ROLE_NUM_SHORTAGE_TYPES = 3;

--Variables to store dungeon info in Lua
--local LFDDungeonList, LFRRaidList, LFGCollapseList, LFGEnabledList, LFDHiddenByCollapseList, LFGLockList;

function LFGEventFrame_OnLoad(self)
	self:RegisterEvent("LFG_UPDATE");
	self:RegisterEvent("PLAYER_ENTERING_WORLD");
	self:RegisterEvent("LFG_LOCK_INFO_RECEIVED");
	self:RegisterEvent("PARTY_MEMBERS_CHANGED");
	
	self:RegisterEvent("LFG_OFFER_CONTINUE");
	self:RegisterEvent("LFG_ROLE_CHECK_ROLE_CHOSEN");
	
	self:RegisterEvent("LFG_PROPOSAL_UPDATE");
	self:RegisterEvent("LFG_PROPOSAL_SHOW");
	self:RegisterEvent("LFG_PROPOSAL_FAILED");
	self:RegisterEvent("LFG_PROPOSAL_SUCCEEDED");
	
	self:RegisterEvent("VARIABLES_LOADED");
	
	--These just update states (roles changeable, buttons clickable, etc.)
	self:RegisterEvent("LFG_ROLE_CHECK_SHOW");
	self:RegisterEvent("LFG_ROLE_CHECK_HIDE");
	self:RegisterEvent("LFG_BOOT_PROPOSAL_UPDATE");
	self:RegisterEvent("LFG_ROLE_UPDATE");
	self:RegisterEvent("LFG_UPDATE_RANDOM_INFO");
end

LFGQueuedForList = {};
function LFGEventFrame_OnEvent(self, event, ...)
	if ( event == "LFG_UPDATE" ) then
		LFG_UpdateQueuedList();
	elseif ( event == "PLAYER_ENTERING_WORLD" ) then
		LFG_UpdateQueuedList();
		LFG_UpdateRoleCheckboxes();
	elseif ( event == "LFG_LOCK_INFO_RECEIVED" ) then
		LFGLockList = GetLFDChoiceLockedState();
		LFG_UpdateFramesIfShown();
	elseif ( event == "PARTY_MEMBERS_CHANGED" ) then
		LFG_UpdateQueuedList();
		LFG_UpdateFramesIfShown();
		if ( not CanPartyLFGBackfill() ) then
			StaticPopup_Hide("LFG_OFFER_CONTINUE");
		end
	elseif ( event == "LFG_OFFER_CONTINUE" ) then
		local displayName, lfgID, typeID = ...;
		local dialog = StaticPopup_Show("LFG_OFFER_CONTINUE", NORMAL_FONT_COLOR_CODE..displayName.."|r");
		if ( dialog ) then
			dialog.data = lfgID;
			dialog.data2 = typeID;
		end
	elseif ( event == "LFG_ROLE_CHECK_ROLE_CHOSEN" ) then
		local player, isTank, isHealer, isDamage = ...;

		--Yes, consecutive string concatenation == bad for garbage collection. But the alternative is either extremely unslightly or localization unfriendly. (Also, this happens fairly rarely)
		local roleList;
		
		if ( isTank ) then
			roleList = INLINE_TANK_ICON.." "..TANK;
		end
		if ( isHealer ) then
			if ( roleList ) then
				roleList = roleList..PLAYER_LIST_DELIMITER.." "..INLINE_HEALER_ICON.." "..HEALER;
			else
				roleList = INLINE_HEALER_ICON.." "..HEALER;
			end
		end
		if ( isDamage ) then
			if ( roleList ) then
				roleList = roleList..PLAYER_LIST_DELIMITER.." "..INLINE_DAMAGER_ICON.." "..DAMAGER;
			else
				roleList = INLINE_DAMAGER_ICON.." "..DAMAGER;
			end
		end
		assert(roleList);
		ChatFrame_DisplaySystemMessageInPrimary(string.format(LFG_ROLE_CHECK_ROLE_CHOSEN, player, roleList));
	elseif ( event == "VARIABLES_LOADED" ) then
		LFG_UpdateRoleCheckboxes();
	elseif ( event == "LFG_ROLE_UPDATE" ) then
		LFG_UpdateRoleCheckboxes();
	elseif ( event == "LFG_PROPOSAL_UPDATE" ) then
		LFGDungeonReadyPopup_Update();
	elseif ( event == "LFG_PROPOSAL_SHOW" ) then
		LFGDungeonReadyPopup.closeIn = nil;
		LFGDungeonReadyPopup:SetScript("OnUpdate", nil);
		LFGDungeonReadyStatus_ResetReadyStates();
		StaticPopupSpecial_Show(LFGDungeonReadyPopup);
		LFGSearchStatus:Hide();
		PlaySound("ReadyCheck");
	elseif ( event == "LFG_PROPOSAL_FAILED" ) then
		LFGDungeonReadyPopup_OnFail();
	elseif ( event == "LFG_PROPOSAL_SUCCEEDED" ) then
		LFGDebug("Proposal Hidden: Proposal succeeded.");
		StaticPopupSpecial_Hide(LFGDungeonReadyPopup);
	end
	
	LFG_UpdateRolesChangeable();
	LFG_UpdateFindGroupButtons();
	LFG_UpdateLockedOutPanels();
	LFDFrame_UpdateBackfill();
end

function LFG_UpdateLockedOutPanels()
	local mode, submode = GetLFGMode();
	
	if ( mode == "listed" ) then
		LFDQueueFrameNoLFDWhileLFR:Show();
	else
		LFDQueueFrameNoLFDWhileLFR:Hide();
	end
	
	if ( mode == "queued" or mode == "proposal" or mode == "rolecheck" ) then
		LFRQueueFrameNoLFRWhileLFD:Show();
	else
		LFRQueueFrameNoLFRWhileLFD:Hide();
	end
end

function LFG_UpdateFindGroupButtons()
	LFDQueueFrameFindGroupButton_Update();
	LFRQueueFrameFindGroupButton_Update();
end

function LFG_UpdateQueuedList()
	GetLFGQueuedList(LFGQueuedForList);
	LFG_UpdateFramesIfShown();
	MiniMapLFG_UpdateIsShown();
end

function LFG_UpdateFramesIfShown()
	if ( LFDParentFrame:IsShown() ) then
		LFDQueueFrame_Update();
	end
	if ( LFRParentFrame:IsVisible() ) then
		LFRQueueFrame_Update();
	end
end

function LFG_PermanentlyDisableRoleButton(button)
	button.permDisabled = true;
	button:Disable();
	SetDesaturation(button:GetNormalTexture(), true);
	button.cover:Show();
	button.cover:SetAlpha(0.7);
	button.checkButton:Hide();
	button.checkButton:Disable();
	if ( button.background ) then
		button.background:Hide();
	end
	if ( button.shortageBorder ) then
		button.shortageBorder:SetVertexColor(0.5, 0.5, 0.5);
		button.incentiveIcon.texture:SetVertexColor(0.5, 0.5, 0.5);
		button.incentiveIcon.border:SetVertexColor(0.5, 0.5, 0.5);
	end
end

function LFG_DisableRoleButton(button)
	button:Disable();
	button.cover:Show();
	if ( not button.permDisabled ) then
		button.cover:SetAlpha(0.5);
	end
	button.checkButton:Disable();
	if ( button.background ) then
		button.background:Hide();
	end
	if ( button.shortageBorder ) then
		button.shortageBorder:SetVertexColor(0.5, 0.5, 0.5);
		button.incentiveIcon.texture:SetVertexColor(0.5, 0.5, 0.5);
		button.incentiveIcon.border:SetVertexColor(0.5, 0.5, 0.5);
	end
end

function LFG_EnableRoleButton(button)
	button.permDisabled = false;
	button:Enable();
	SetDesaturation(button:GetNormalTexture(), false);
	button.cover:Hide();
	button.checkButton:Show();
	button.checkButton:Enable();
	if ( button.background ) then
		button.background:Show();
	end
	if ( button.shortageBorder ) then
		button.shortageBorder:SetVertexColor(1, 1, 1);
		button.incentiveIcon.texture:SetVertexColor(1, 1, 1);
		button.incentiveIcon.border:SetVertexColor(1, 1, 1);
	end
end

function LFG_UpdateAvailableRoles()
	local canBeTank, canBeHealer, canBeDPS = UnitGetAvailableRoles("player");
	
	if ( canBeTank ) then
		LFG_EnableRoleButton(LFDQueueFrameRoleButtonTank);
		LFG_EnableRoleButton(LFRQueueFrameRoleButtonTank);
		LFG_EnableRoleButton(LFDRoleCheckPopupRoleButtonTank);
		LFG_EnableRoleButton(RaidFinderQueueFrameRoleButtonTank);
	else
		LFG_PermanentlyDisableRoleButton(LFDQueueFrameRoleButtonTank);
		LFG_PermanentlyDisableRoleButton(LFRQueueFrameRoleButtonTank);
		LFG_PermanentlyDisableRoleButton(LFDRoleCheckPopupRoleButtonTank);
		LFG_PermanentlyDisableRoleButton(RaidFinderQueueFrameRoleButtonTank);
	end
	
	if ( canBeHealer ) then
		LFG_EnableRoleButton(LFDQueueFrameRoleButtonHealer);
		LFG_EnableRoleButton(LFRQueueFrameRoleButtonHealer);
		LFG_EnableRoleButton(LFDRoleCheckPopupRoleButtonHealer);
		LFG_EnableRoleButton(RaidFinderQueueFrameRoleButtonHealer);
	else
		LFG_PermanentlyDisableRoleButton(LFDQueueFrameRoleButtonHealer);
		LFG_PermanentlyDisableRoleButton(LFRQueueFrameRoleButtonHealer);
		LFG_PermanentlyDisableRoleButton(LFDRoleCheckPopupRoleButtonHealer);
		LFG_PermanentlyDisableRoleButton(RaidFinderQueueFrameRoleButtonHealer);
	end
	
	if ( canBeDPS ) then
		LFG_EnableRoleButton(LFDQueueFrameRoleButtonDPS);
		LFG_EnableRoleButton(LFRQueueFrameRoleButtonDPS);
		LFG_EnableRoleButton(LFDRoleCheckPopupRoleButtonDPS);
		LFG_EnableRoleButton(RaidFinderQueueFrameRoleButtonDPS);
	else
		LFG_PermanentlyDisableRoleButton(LFDQueueFrameRoleButtonDPS);
		LFG_PermanentlyDisableRoleButton(LFRQueueFrameRoleButtonDPS);
		LFG_PermanentlyDisableRoleButton(LFDRoleCheckPopupRoleButtonDPS);
		LFG_PermanentlyDisableRoleButton(RaidFinderQueueFrameRoleButtonDPS);
	end
	
	local canChangeLeader = (GetNumPartyMembers() == 0 or IsPartyLeader()) and (GetNumRaidMembers() == 0 or IsRaidLeader());
	if ( canChangeLeader ) then
		LFG_EnableRoleButton(LFDQueueFrameRoleButtonLeader);
		LFG_EnableRoleButton(RaidFinderQueueFrameRoleButtonLeader);
	else
		LFG_PermanentlyDisableRoleButton(LFDQueueFrameRoleButtonLeader);
		LFG_PermanentlyDisableRoleButton(RaidFinderQueueFrameRoleButtonLeader);
	end
end

function LFG_UpdateRoleCheckboxes()
	local leader, tank, healer, dps = GetLFGRoles();
	
	LFDQueueFrameRoleButtonLeader.checkButton:SetChecked(leader);
	RaidFinderQueueFrameRoleButtonLeader.checkButton:SetChecked(leader);
	
	LFDQueueFrameRoleButtonTank.checkButton:SetChecked(tank);
	LFRQueueFrameRoleButtonTank.checkButton:SetChecked(tank);
	LFDRoleCheckPopupRoleButtonTank.checkButton:SetChecked(tank);
	RaidFinderQueueFrameRoleButtonTank.checkButton:SetChecked(tank);
	
	LFDQueueFrameRoleButtonHealer.checkButton:SetChecked(healer);
	LFRQueueFrameRoleButtonHealer.checkButton:SetChecked(healer);
	LFDRoleCheckPopupRoleButtonHealer.checkButton:SetChecked(healer);
	RaidFinderQueueFrameRoleButtonHealer.checkButton:SetChecked(healer);
	
	LFDQueueFrameRoleButtonDPS.checkButton:SetChecked(dps);
	LFRQueueFrameRoleButtonDPS.checkButton:SetChecked(dps);
	LFDRoleCheckPopupRoleButtonDPS.checkButton:SetChecked(dps);
	RaidFinderQueueFrameRoleButtonDPS.checkButton:SetChecked(dps);
end

function LFG_UpdateRolesChangeable()
	local mode, subMode = GetLFGMode();
	if ( mode == "queued" or mode == "listed" or mode == "rolecheck" or mode == "proposal" ) then
		LFG_DisableRoleButton(LFDQueueFrameRoleButtonTank, true);
		LFG_DisableRoleButton(LFRQueueFrameRoleButtonTank, true);
		
		LFG_DisableRoleButton(LFDQueueFrameRoleButtonHealer, true);
		LFG_DisableRoleButton(LFRQueueFrameRoleButtonHealer, true);
		
		LFG_DisableRoleButton(LFDQueueFrameRoleButtonDPS, true);
		LFG_DisableRoleButton(LFRQueueFrameRoleButtonDPS, true);
		
		LFG_DisableRoleButton(LFDQueueFrameRoleButtonLeader, true);
	else
		LFG_UpdateAvailableRoles();
	end
end

function LFG_SetRoleIconIncentive(roleButton, incentiveIndex)
	if ( incentiveIndex ) then
		local tex;
		if ( incentiveIndex == LFG_ROLE_SHORTAGE_PLENTIFUL ) then
			tex = "Interface\\Icons\\INV_Misc_Coin_19";
		elseif ( incentiveIndex == LFG_ROLE_SHORTAGE_UNCOMMON ) then
			tex = "Interface\\Icons\\INV_Misc_Coin_18";
		elseif ( incentiveIndex == LFG_ROLE_SHORTAGE_RARE ) then
			tex = "Interface\\Icons\\INV_Misc_Coin_17";
		end
		SetPortraitToTexture(roleButton.incentiveIcon.texture, tex);
		roleButton.incentiveIcon:Show();
		roleButton.shortageBorder:Show();
	else
		roleButton.incentiveIcon:Hide();
		roleButton.shortageBorder:Hide();
	end
end

function LFGRoleIconIncentive_OnEnter(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
	local role = LFG_ID_TO_ROLES[self:GetParent():GetID()];
	
	GameTooltip:SetText(format(LFG_CALL_TO_ARMS, _G[role]), 1, 1, 1);
	GameTooltip:AddLine(LFG_CALL_TO_ARMS_EXPLANATION, nil, nil, nil, 1);
	GameTooltip:Show();
end

function LFGSpecificChoiceEnableButton_SetIsRadio(button, isRadio)
	if ( isRadio ) then
		button:SetSize(17, 17)
		button:SetNormalTexture("Interface\\Buttons\\UI-RadioButton");
		button:GetNormalTexture():SetTexCoord(0, 0.25, 0, 1);
		
		button:SetHighlightTexture("Interface\\Buttons\\UI-RadioButton");
		button:GetHighlightTexture():SetTexCoord(0.5, 0.75, 0, 1);
		
		button:SetCheckedTexture("Interface\\Buttons\\UI-RadioButton");
		button:GetCheckedTexture():SetTexCoord(0.25, 0.5, 0, 1);
		
		button:SetPushedTexture("Interface\\Buttons\\UI-RadioButton");
		button:GetPushedTexture():SetTexCoord(0, 0.25, 0, 1);
		
		button:SetDisabledCheckedTexture("Interface\\Buttons\\UI-RadioButton");
		button:GetDisabledCheckedTexture():SetTexCoord(0.75, 1, 0, 1);
	else
		button:SetSize(20, 20);
		button:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up");
		button:GetNormalTexture():SetTexCoord(0, 1, 0, 1);
		
		button:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight");
		button:GetHighlightTexture():SetTexCoord(0, 1, 0, 1);
		
		button:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check");
		button:GetCheckedTexture():SetTexCoord(0, 1, 0, 1);
		
		button:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down");
		button:GetPushedTexture():SetTexCoord(0, 1, 0, 1);
		
		button:SetDisabledCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check-Disabled");
		button:GetDisabledCheckedTexture():SetTexCoord(0, 1, 0, 1);
	end	
end

--More functions

function GetTexCoordsForRole(role)
	local textureHeight, textureWidth = 256, 256;
	local roleHeight, roleWidth = 67, 67;
	
	if ( role == "GUIDE" ) then
		return GetTexCoordsByGrid(1, 1, textureWidth, textureHeight, roleWidth, roleHeight);
	elseif ( role == "TANK" ) then
		return GetTexCoordsByGrid(1, 2, textureWidth, textureHeight, roleWidth, roleHeight);
	elseif ( role == "HEALER" ) then
		return GetTexCoordsByGrid(2, 1, textureWidth, textureHeight, roleWidth, roleHeight);
	elseif ( role == "DAMAGER" ) then
		return GetTexCoordsByGrid(2, 2, textureWidth, textureHeight, roleWidth, roleHeight);
	else
		error("Unknown role: "..tostring(role));
	end
end

function GetBackgroundTexCoordsForRole(role)
	local textureHeight, textureWidth = 128, 256;
	local roleHeight, roleWidth = 75, 75;
	
	if ( role == "TANK" ) then
		return GetTexCoordsByGrid(2, 1, textureWidth, textureHeight, roleWidth, roleHeight);
	elseif ( role == "HEALER" ) then
		return GetTexCoordsByGrid(1, 1, textureWidth, textureHeight, roleWidth, roleHeight);
	elseif ( role == "DAMAGER" ) then
		return GetTexCoordsByGrid(3, 1, textureWidth, textureHeight, roleWidth, roleHeight);
	else
		error("Role does not have background: "..tostring(role));
	end
end

function GetTexCoordsForRoleSmallCircle(role)
	if ( role == "TANK" ) then
		return 0, 19/64, 22/64, 41/64;
	elseif ( role == "HEALER" ) then
		return 20/64, 39/64, 1/64, 20/64;
	elseif ( role == "DAMAGER" ) then
		return 20/64, 39/64, 22/64, 41/64;
	else
		error("Unknown role: "..tostring(role));
	end
end

function GetTexCoordsForRoleSmall(role)
	if ( role == "TANK" ) then
		return 0.5, 0.75, 0, 1;
	elseif ( role == "HEALER" ) then
		return 0.75, 1, 0, 1;
	elseif ( role == "DAMAGER" ) then
		return 0.25, 0.5, 0, 1;
	else
		error("Unknown role: "..tostring(role));
	end
end

function LFGFrameRoleCheckButton_OnEnter(self)
	if ( self.checkButton:IsEnabled() == 1 ) then
		self.checkButton:LockHighlight();
	end
end

function LFGConstructDeclinedMessage(dungeonID)
	local returnVal;
	for i=1, GetLFDLockPlayerCount() do
		local playerName, lockedReason, subReason1, subReason2 = GetLFDLockInfo(dungeonID, i);
		if ( lockedReason ~= 0 ) then
			local who;
			if ( i == 1 ) then
				who = "SELF_";
			else
				who = "OTHER_";
			end
			if ( returnVal ) then
				returnVal = returnVal.."\n"..format(_G["INSTANCE_UNAVAILABLE_"..who..(LFG_INSTANCE_INVALID_CODES[lockedReason] or "OTHER")], playerName, subReason1, subReason2);
			else
				returnVal = format(_G["INSTANCE_UNAVAILABLE_"..who..(LFG_INSTANCE_INVALID_CODES[lockedReason] or "OTHER")], playerName, subReason1, subReason2);
			end
		end
	end
	return returnVal;
end

--Queued status functions

local NUM_TANKS = 1;
local NUM_HEALERS = 1;
local NUM_DAMAGERS = 3;

function LFGSearchStatus_OnEvent(self, event, ...)
	if ( event == "LFG_QUEUE_STATUS_UPDATE" ) then
		LFGSearchStatus_Update();
	end
end

function LFGSearchStatus_SetMode(mode)
	if ( mode == "individual" ) then
		LFGSearchStatus.mode = "individual";
		LFGSearchStatusIndividualRoleDisplay:Show();
		LFGSearchStatusGroupedRoleDisplay:Hide();
	elseif ( mode == "grouped" ) then
		LFGSearchStatus.mode = "grouped";
		LFGSearchStatusIndividualRoleDisplay:Hide();
		LFGSearchStatusGroupedRoleDisplay:Show();
	else
		GMError("Unknown mode");
	end
end

function LFGSearchStatusPlayer_SetFound(button, isFound)
	if ( isFound ) then
		SetDesaturation(button.texture, false);
		button.cover:Hide();
	else
		SetDesaturation(button.texture, true);
		button.cover:Show();
	end
end

function LFGSearchStatus_UpdateRoles()
	local leader, tank, healer, damage = GetLFGRoles();
	local currentIcon = 1;
	if ( tank ) then
		local icon = _G["LFGSearchStatusRoleIcon"..currentIcon]
		icon:SetTexCoord(GetTexCoordsForRole("TANK"));
		icon:Show();
		currentIcon = currentIcon + 1;
	end
	if ( healer ) then
		local icon = _G["LFGSearchStatusRoleIcon"..currentIcon]
		icon:SetTexCoord(GetTexCoordsForRole("HEALER"));
		icon:Show();
		currentIcon = currentIcon + 1;
	end
	if ( damage ) then
		local icon = _G["LFGSearchStatusRoleIcon"..currentIcon]
		icon:SetTexCoord(GetTexCoordsForRole("DAMAGER"));
		icon:Show();
		currentIcon = currentIcon + 1;
	end
	for i=currentIcon, LFD_NUM_ROLES do
		_G["LFGSearchStatusRoleIcon"..i]:Hide();
	end
	local extraWidth = 27*(currentIcon-1);
	LFGSearchStatusLookingFor:SetPoint("BOTTOM", -extraWidth/2, 14);
end

function LFGSearchStatus_Update()
	local LFGSearchStatus = LFGSearchStatus;
	local hasData,  leaderNeeds, tankNeeds, healerNeeds, dpsNeeds, instanceType, instanceName, averageWait, tankWait, healerWait, damageWait, myWait, queuedTime = GetLFGQueueStats();
	
	LFGSearchStatus_UpdateRoles();
	
	local displayHeight = 145;
	if ( LFGSearchStatus.mode == "grouped" ) then
		displayHeight = displayHeight + 20;
	end
	
	if ( not hasData ) then
		LFGSearchStatus:SetHeight(displayHeight);
		LFGSearchStatus_SetRolesFound(0, 0, 0);
		LFGSearchStatus.statistic:Hide();
		LFGSearchStatus.elapsedWait:SetFormattedText(TIME_IN_QUEUE, LESS_THAN_ONE_MINUTE);
		
		LFGSearchStatus:SetScript("OnUpdate", nil);
		return;
	end
	
	if ( instancetype == TYPEID_HEROIC_DIFFICULTY ) then
		instanceName = format(HEROIC_PREFIX, instanceName);
	end
	
	--This won't work if we decide the makeup is, say, 3 healers, 1 damage, 1 tank.
	LFGSearchStatus_SetRolesFound(NUM_TANKS - tankNeeds, NUM_HEALERS - healerNeeds, NUM_DAMAGERS - dpsNeeds);
	
	LFGSearchStatus.queuedTime = queuedTime;
	local elapsedTime = GetTime() - queuedTime;
	LFGSearchStatus.elapsedWait:SetFormattedText(TIME_IN_QUEUE, (elapsedTime >= 60) and SecondsToTime(elapsedTime) or LESS_THAN_ONE_MINUTE);
	LFGSearchStatus.elapsedWait:Show();
	
	if ( myWait == -1 ) then
		LFGSearchStatus.statistic:Hide();
	else
		LFGSearchStatus.statistic:Show();
		displayHeight = displayHeight + 25;
		LFGSearchStatus.statistic:SetFormattedText(LFG_STATISTIC_AVERAGE_WAIT, myWait == -1 and TIME_UNKNOWN or SecondsToTime(myWait, false, false, 1));
	end
	LFGSearchStatus:SetHeight(displayHeight);
	LFGSearchStatus:SetScript("OnUpdate", LFGSearchStatus_OnUpdate);
end

function LFGSearchStatus_SetRolesFound(tanksFound, healersFound, damageFound)
	if ( LFGSearchStatus.mode == "individual" ) then
		LFGSearchStatusPlayer_SetFound(LFGSearchStatusIndividualRoleDisplayTank1, (tanksFound > 0));
		LFGSearchStatusPlayer_SetFound(LFGSearchStatusIndividualRoleDisplayHealer1, (healersFound > 0));
		
		for i=1, NUM_DAMAGERS do
			LFGSearchStatusPlayer_SetFound(_G["LFGSearchStatusIndividualRoleDisplayDamage"..i], i <= damageFound);
		end
	else
		LFGSearchStatusPlayer_SetFound(LFGSearchStatusGroupedRoleDisplayTank, tanksFound == NUM_TANKS);
		LFGSearchStatusPlayer_SetFound(LFGSearchStatusGroupedRoleDisplayHealer, healersFound == NUM_HEALERS);
		LFGSearchStatusPlayer_SetFound(LFGSearchStatusGroupedRoleDisplayDamage, damageFound == NUM_DAMAGERS);
		
		LFGSearchStatusGroupedRoleDisplayTank.count:SetFormattedText(PLAYERS_FOUND_OUT_OF_MAX, tanksFound, NUM_TANKS);
		LFGSearchStatusGroupedRoleDisplayHealer.count:SetFormattedText(PLAYERS_FOUND_OUT_OF_MAX, healersFound, NUM_HEALERS);
		LFGSearchStatusGroupedRoleDisplayDamage.count:SetFormattedText(PLAYERS_FOUND_OUT_OF_MAX, damageFound, NUM_DAMAGERS);
	end
end

function LFGSearchStatus_OnUpdate(self, elapsed)
	local elapsedTime = GetTime() - self.queuedTime;
	self.elapsedWait:SetFormattedText(TIME_IN_QUEUE, (elapsedTime >= 60) and SecondsToTime(elapsedTime) or LESS_THAN_ONE_MINUTE);
end

--Ready popup functions

function LFGDungeonReadyPopup_OnFail()
	PlaySound("LFG_Denied");
	if ( LFGDungeonReadyDialog:IsShown() ) then
		LFGDebug("Proposal Hidden: Proposal failed.");
		StaticPopupSpecial_Hide(LFGDungeonReadyPopup);
	elseif ( LFGDungeonReadyPopup:IsShown() ) then
		LFGDungeonReadyPopup.closeIn = LFD_PROPOSAL_FAILED_CLOSE_TIME;
		LFGDungeonReadyPopup:SetScript("OnUpdate", LFGDungeonReadyPopup_OnUpdate);
	end
end

function LFGDungeonReadyPopup_OnUpdate(self, elapsed)
	self.closeIn = self.closeIn - elapsed;
	if ( self.closeIn < 0 ) then	--We remove the OnUpdate and closeIn OnHide
		LFGDebug("Proposal Hidden: Failure close timer expired.");
		StaticPopupSpecial_Hide(LFGDungeonReadyPopup);
	end
end

function LFGDungeonReadyPopup_Update()	
	local proposalExists, typeID, id, name, texture, role, hasResponded, totalEncounters, completedEncounters, numMembers, isLeader = GetLFGProposal();
	local isRaid = false;
	if ( not proposalExists ) then
		LFGDebug("Proposal Hidden: No proposal exists.");
		StaticPopupSpecial_Hide(LFGDungeonReadyPopup);
		return;
	end
	
	LFGDungeonReadyPopup.dungeonID = id;
	
	if ( hasResponded ) then
		if ( isRaid ) then
			LFGDungeonReadyStatus:Show();
			LFGDungeonReadyStatusIndividual:Hide();
			LFGDungeonReadyStatusGrouped:Show();
			LFGDungeonReadyDialog:Hide();
			
			LFGDungeonReadyStatusGrouped_UpdateIcon(LFGDungeonReadyStatusGroupedTank, "TANK", numMembers);
			LFGDungeonReadyStatusGrouped_UpdateIcon(LFGDungeonReadyStatusGroupedHealer, "HEALER", numMembers);
			LFGDungeonReadyStatusGrouped_UpdateIcon(LFGDungeonReadyStatusGroupedDamager, "DAMAGER", numMembers);
			
			if ( not LFGDungeonReadyPopup:IsShown() or StaticPopup_IsLastDisplayedFrame(LFGDungeonReadyPopup) ) then
				LFGDungeonReadyPopup:SetHeight(LFGDungeonReadyStatus:GetHeight());
			end
		else
			LFGDungeonReadyStatus:Show();
			LFGDungeonReadyStatusGrouped:Hide();
			LFGDungeonReadyStatusIndividual:Show();
			LFGDungeonReadyDialog:Hide();
			
			for i=1, numMembers do
				LFGDungeonReadyStatusIndividual_UpdateIcon(_G["LFGDungeonReadyStatusIndividualPlayer"..i]);
			end
			for i=numMembers+1, NUM_LFD_MEMBERS do
				_G["LFGDungeonReadyStatusIndividualPlayer"..i]:Hide();
			end
		
			if ( not LFGDungeonReadyPopup:IsShown() or StaticPopup_IsLastDisplayedFrame(LFGDungeonReadyPopup) ) then
				LFGDungeonReadyPopup:SetHeight(LFGDungeonReadyStatus:GetHeight());
			end
		end
	else
		LFGDungeonReadyDialog:Show();
		LFGDungeonReadyStatus:Hide();
	
		local LFGDungeonReadyDialog = LFGDungeonReadyDialog; --Make a local copy.
		
		if ( typeID == TYPEID_RANDOM_DUNGEON ) then
			LFGDungeonReadyDialog.background:SetTexture("Interface\\LFGFrame\\UI-LFG-BACKGROUND-RANDOMDUNGEON");
			
			LFGDungeonReadyDialog.label:SetText(RANDOM_DUNGEON_IS_READY);
			
			LFGDungeonReadyDialog.instanceInfo:Hide();
			
			if ( completedEncounters > 0 ) then
				LFGDungeonReadyDialog.randomInProgress:Show();
				LFGDungeonReadyPopup:SetHeight(223);
				LFGDungeonReadyDialog.background:SetTexCoord(0, 1, 0, 1);
			else
				LFGDungeonReadyDialog.randomInProgress:Hide();
				LFGDungeonReadyPopup:SetHeight(193);
				LFGDungeonReadyDialog.background:SetTexCoord(0, 1, 0, 118/128);
			end
		else
			LFGDungeonReadyDialog.randomInProgress:Hide();
			LFGDungeonReadyPopup:SetHeight(223);
			LFGDungeonReadyDialog.background:SetTexCoord(0, 1, 0, 1);
			texture = "Interface\\LFGFrame\\UI-LFG-BACKGROUND-"..texture;
			if ( not LFGDungeonReadyDialog.background:SetTexture(texture) ) then	--We haven't added this texture yet. Default to the Deadmines.
				LFGDungeonReadyDialog.background:SetTexture("Interface\\LFGFrame\\UI-LFG-BACKGROUND-Deadmines");	--DEBUG FIXME Default probably shouldn't be Deadmines
			end
			
			LFGDungeonReadyDialog.label:SetText(SPECIFIC_DUNGEON_IS_READY);
			LFGDungeonReadyDialog_UpdateInstanceInfo(name, completedEncounters, totalEncounters);
			LFGDungeonReadyDialog.instanceInfo:Show();
		end

		
		LFGDungeonReadyDialogRoleIconTexture:SetTexCoord(GetTexCoordsForRole(role));
		LFGDungeonReadyDialogRoleLabel:SetText(_G[role]);
		if ( isLeader ) then
			LFGDungeonReadyDialogRoleIconLeaderIcon:Show();
		else
			LFGDungeonReadyDialogRoleIconLeaderIcon:Hide();
		end
		
		LFGDungeonReadyDialog_UpdateRewards(id, role);
	end
end

function LFGDungeonReadyDialog_UpdateRewards(dungeonID, role)
	local doneToday, moneyBase, moneyVar, experienceBase, experienceVar, numRewards = GetLFGDungeonRewards(dungeonID);
	
	local numRandoms = 4 - GetNumPartyMembers();
	local moneyAmount = moneyBase + moneyVar * numRandoms;
	local experienceGained = experienceBase + experienceVar * numRandoms;
	
	local frameID = 1;

	if ( moneyAmount > 0 or experienceGained > 0 ) then --hasMiscReward ) then
		LFGDungeonReadyDialogReward_SetMisc(LFGDungeonReadyDialogRewardsFrameReward1);
		frameID = 2;
	end
	
	if ( moneyAmount == 0 and experienceGained == 0 and numRewards == 0 ) then
		LFGDungeonReadyDialogRewardsFrameLabel:Hide();
	else
		LFGDungeonReadyDialogRewardsFrameLabel:Show();
	end
	
	for i = 1, numRewards do
		local frame = _G["LFGDungeonReadyDialogRewardsFrameReward"..frameID];
		if ( not frame ) then
			frame = CreateFrame("FRAME", "LFGDungeonReadyDialogRewardsFrameReward"..frameID, LFGDungeonReadyDialogRewardsFrame, "LFGDungeonReadyRewardTemplate");
			frame:SetID(frameID);
			LFD_MAX_REWARDS = frameID;
		end
		LFGDungeonReadyDialogReward_SetReward(frame, dungeonID, i, "reward")
		frameID = frameID + 1;
	end
	
	for shortageIndex = 1, LFG_ROLE_NUM_SHORTAGE_TYPES do
		local eligible, forTank, forHealer, forDamage, itemCount = GetLFGRoleShortageRewards(dungeonID, shortageIndex);
		if ( eligible and ((role == "TANK" and forTank) or (role == "HEALER" and forHealer) or (role == "DAMAGER" and forDamage)) ) then
			for rewardIndex=1, itemCount do
				local frame = _G["LFGDungeonReadyDialogRewardsFrameReward"..frameID];
				if ( not frame ) then
					frame = CreateFrame("FRAME", "LFGDungeonReadyDialogRewardsFrameReward"..frameID, LFGDungeonReadyDialogRewardsFrame, "LFGDungeonReadyRewardTemplate");
					frame:SetID(frameID);
					LFD_MAX_REWARDS = frameID;
				end
				LFGDungeonReadyDialogReward_SetReward(frame, dungeonID, rewardIndex, "shortage", shortageIndex);
				frameID = frameID + 1;
			end
		end
	end
	
	--Hide the unused ones
	for i = frameID, LFD_MAX_REWARDS do
		_G["LFGDungeonReadyDialogRewardsFrameReward"..i]:Hide();
	end
	
	local usedButtons= frameID - 1;
	
	if ( usedButtons > 0 ) then
		--Set up positions
		local iconOffset;
		if ( usedButtons > 2 ) then
			iconOffset = -5;
		else
			iconOffset = 0;
		end
		local area = usedButtons * LFGDungeonReadyDialogRewardsFrameReward1:GetWidth() + (usedButtons - 1) * iconOffset;
		
		LFGDungeonReadyDialogRewardsFrameReward1:SetPoint("LEFT", LFGDungeonReadyDialogRewardsFrame, "CENTER", -area/2, 5);
		for i = 2, usedButtons do
			_G["LFGDungeonReadyDialogRewardsFrameReward"..i]:SetPoint("LEFT", "LFGDungeonReadyDialogRewardsFrameReward"..(i - 1), "RIGHT", iconOffset, 0);
		end
	end
end

function LFGDungeonReadyDialogReward_SetMisc(button)
	SetPortraitToTexture(button.texture, "Interface\\Icons\\inv_misc_coin_02");
	button.rewardType = "misc";
	button:Show();
end

function LFGDungeonReadyDialogReward_SetReward(button, dungeonID, rewardIndex, rewardType, rewardArg)
	local name, texturePath, quantity;
	if ( rewardType == "reward" ) then
		name, texturePath, quantity = GetLFGDungeonRewardInfo(dungeonID, rewardIndex);
	elseif ( rewardType == "shortage" ) then
		name, texturePath, quantity = GetLFGDungeonShortageRewardInfo(dungeonID, rewardArg, rewardIndex);
	end
	if ( texturePath ) then	--Otherwise, we may be waiting on the item data to come from the server.
		SetPortraitToTexture(button.texture, texturePath);
	end
	button.rewardType = rewardType;
	button.rewardID = rewardIndex;
	button.rewardArg = rewardArg;
	button:Show();
end
	
function LFGDungeonReadyDialogReward_OnEnter(self, dungeonID)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
	if ( self.rewardType == "misc" ) then
		GameTooltip:AddLine(REWARD_ITEMS_ONLY);
		local doneToday, moneyBase, moneyVar, experienceBase, experienceVar, numRewards = GetLFGDungeonRewards(LFGDungeonReadyPopup.dungeonID);
		local numRandoms = 4 - GetNumPartyMembers();
		local moneyAmount = moneyBase + moneyVar * numRandoms;
		local experienceGained = experienceBase + experienceVar * numRandoms;
		
		if ( experienceGained > 0 ) then
			GameTooltip:AddLine(string.format(GAIN_EXPERIENCE, experienceGained));
		end
		if ( moneyAmount > 0 ) then
			SetTooltipMoney(GameTooltip, moneyAmount, nil);
		end
	elseif ( self.rewardType == "reward" ) then
		GameTooltip:SetLFGDungeonReward(LFGDungeonReadyPopup.dungeonID, self.rewardID);
	elseif ( self.rewardType == "shortage" ) then
		GameTooltip:SetLFGDungeonShortageReward(LFGDungeonReadyPopup.dungeonID, self.rewardArg, self.rewardID);
	end
	GameTooltip:Show();
end

function LFGDungeonReadyDialog_UpdateInstanceInfo(name, completedEncounters, totalEncounters)
	local instanceInfoFrame = LFGDungeonReadyDialogInstanceInfoFrame;
	instanceInfoFrame.name:SetFontObject(GameFontNormalLarge);
	instanceInfoFrame.name:SetText(name);
	if ( instanceInfoFrame.name:GetWidth() + 20 > LFGDungeonReadyDialog:GetWidth() ) then
		instanceInfoFrame.name:SetFontObject(GameFontNormal);
	end
	
	instanceInfoFrame.statusText:SetFormattedText(BOSSES_KILLED, completedEncounters, totalEncounters);
end

function LFGDungeonReadyDialogInstanceInfo_OnEnter(self)
	local numBosses = select(8, GetLFGProposal());
	local isHoliday = select(12, GetLFGProposal());
	
	if ( numBosses == 0 or isHoliday) then
		return;
	end
	
	GameTooltip:SetOwner(self, "ANCHOR_BOTTOM");
	GameTooltip:AddLine(BOSSES)
	for i=1, numBosses do
		local bossName, texture, isKilled = GetLFGProposalEncounter(i);
		if ( isKilled ) then
			GameTooltip:AddDoubleLine(bossName, BOSS_DEAD, RED_FONT_COLOR.r, RED_FONT_COLOR.g, RED_FONT_COLOR.b, RED_FONT_COLOR.r, RED_FONT_COLOR.g, RED_FONT_COLOR.b);
		else
			GameTooltip:AddDoubleLine(bossName, BOSS_ALIVE, GREEN_FONT_COLOR.r, GREEN_FONT_COLOR.g, GREEN_FONT_COLOR.b, GREEN_FONT_COLOR.r, GREEN_FONT_COLOR.g, GREEN_FONT_COLOR.b);
		end
	end
	GameTooltip:Show();
end

function LFGDungeonReadyStatus_ResetReadyStates()
	for i=1, NUM_LFD_MEMBERS do
		local button = _G["LFGDungeonReadyStatusIndividualPlayer"..i];
		button.readyStatus = "unknown";
	end
end

function LFGDungeonReadyStatusIndividual_UpdateIcon(button)
	local isLeader, role, level, responded, accepted, name, class = GetLFGProposalMember(button:GetID());
	
	button.texture:SetTexCoord(GetTexCoordsForRole(role));
	
	if ( not responded ) then
		button.statusIcon:SetTexture(READY_CHECK_WAITING_TEXTURE);
	elseif ( accepted ) then
		if ( button.readyStatus ~= "accepted" ) then
			button.readyStatus = "accepted";
			PlaySound("LFG_RoleCheck");
		end
		button.statusIcon:SetTexture(READY_CHECK_READY_TEXTURE);
	else
		button.statusIcon:SetTexture(READY_CHECK_NOT_READY_TEXTURE);
	end
	
	button:Show();
end

function LFGDungeonReadyStatusGrouped_UpdateIcon(button, buttonRole, numMembers)
	button.texture:SetTexCoord(GetTexCoordsForRole(buttonRole));
	
	local numTotal, numAccepted = 0, 0;
	local didDecline = false;
	for i=1, numMembers do
		local isLeader, role, level, responded, accepted, name, class = GetLFGProposalMember(i);
		if ( role == buttonRole ) then
			numTotal = numTotal + 1;
			if ( responded ) then
				if ( accepted ) then
					numAccepted = numAccepted + 1;
				else
					didDecline = true;
				end
			end
		end
	end
	
	button.count:SetFormattedText(PLAYERS_FOUND_OUT_OF_MAX, numAccepted, numTotal);
	
	if ( didDecline ) then
		button.statusIcon:SetTexture(READY_CHECK_NOT_READY_TEXTURE);
	elseif ( numAccepted == numTotal ) then
		button.statusIcon:SetTexture(READY_CHECK_READY_TEXTURE);
	else
		button.statusIcon:SetTexture(READY_CHECK_WAITING_TEXTURE);
	end
end

-------Utility functions-----------
function LFDGetNumDungeons()
	return #LFDDungeonList;
end

function LFRGetNumDungeons()
	return #LFRRaidList;
end

function LFGIsIDHeader(id)
	return id < 0;
end

-------List filtering functions-----------
local hasSetUp = false;
function LFGDungeonList_Setup()
	if ( not hasSetUp ) then
		hasSetUp = true;
		LFGCollapseList = GetLFDChoiceCollapseState(LFGCollapseList);	--We maintain this list in Lua
		LFGEnabledList = GetLFDChoiceEnabledState(LFGEnabledList);	--We maintain this list in Lua
		LFGLockList = GetLFDChoiceLockedState(LFGLockList);
		
		LFDQueueFrame_Update();
		LFRQueueFrame_Update();
		return true;
	end
	return false;
end

function LFGQueueFrame_UpdateLFGDungeonList(dungeonList, hiddenByCollapseList, lockList, enableList, collapseList, filter)
	if ( LFGDungeonList_Setup() ) then
		return;
	end
	
	table.wipe(hiddenByCollapseList);
	
	--1. Remove all choices that don't match the filter.
	LFGListFilterChoices(dungeonList, filter);
	
	--2. Remove all headers that have no entries below them.
	LFGListRemoveHeadersWithoutChildren(dungeonList);
	
	--3. Update the enabled state of headers.
	LFGListUpdateHeaderEnabledAndLockedStates(dungeonList, enableList, lockList, hiddenByCollapseList);
	
	--4. Move the children of collapsed headers into the hiddenByCollapse list.
	LFGListRemoveCollapsedChildren(dungeonList, collapseList, hiddenByCollapseList);
end

--filterFunc returns true if the object should be shown.
function LFGListFilterChoices(list, filterFunc)
	local currentPosition = 1;
	while ( currentPosition <= #list ) do
		local id = list[currentPosition];
		local isHeader = LFGIsIDHeader(id);
		if ( isHeader or filterFunc(id) ) then
			currentPosition = currentPosition + 1;
		else
			tremove(list, currentPosition);
		end
	end
end

function LFGListRemoveHeadersWithoutChildren(list)
	--This relies on unparented children coming first.
	local currentPosition = 1;
	--The discrepency between nextObject>IsChild< and >isHeader< is due to the way we want to handle empty values.
	local nextObjectIsChild = not LFGIsIDHeader(list[1] or 0);
	while ( currentPosition <= #list ) do
		local isHeader = not nextObjectIsChild;
		nextObjectIsChild = currentPosition < #list and not LFGIsIDHeader(list[currentPosition+1]);
		if ( isHeader and not nextObjectIsChild ) then
			tremove(list, currentPosition);
		else
			currentPosition = currentPosition + 1;
		end
	end
end

--false = no children so far
--0 = all children unchecked
--1 = some children checked, some unchecked
--2 = all children checked
function LFGListUpdateHeaderEnabledAndLockedStates(dungeonList, enabledList, lockList, hiddenByCollapseList)
	for i=1, #dungeonList do
		local id = dungeonList[i];
		if ( LFGIsIDHeader(id) ) then
			enabledList[id] = false;
			lockList[id] = true;
		elseif ( not lockList[id] ) then
			local groupID = select(LFG_RETURN_VALUES.groupID, GetLFGDungeonInfo(id));
			lockList[groupID] = false;
			local idState = enabledList[id];
			local groupState = enabledList[groupID];
			if ( idState ) then
				if ( not groupState or groupState == 2 ) then
					enabledList[groupID] = 2;
				elseif ( groupState == 0 or groupState == 1 ) then
					enabledList[groupID] = 1;
				end
			else
				if ( not groupState or groupState == 0 ) then
					enabledList[groupID] = 0;
				elseif ( groupState == 1 or groupState == 2 ) then
					enabledList[groupID]  = 1;
				end
			end
		end
	end
	for i=1, #hiddenByCollapseList do
		local id = hiddenByCollapseList[i];
		if ( LFGIsIDHeader(id) ) then
			enabledList[id] = false;
			lockList[id] = true;
		elseif ( not lockList[id] ) then
			local groupID = select(LFG_RETURN_VALUES.groupID, GetLFGDungeonInfo(id));
			lockList[groupID] = false;
			local idState = enabledList[id];
			local groupState = enabledList[groupID];
			if ( idState ) then
				if ( not groupState or groupState == 2 ) then
					enabledList[groupID] = 2;
				elseif ( groupState == 0 or groupState == 1 ) then
					enabledList[groupID] = 1;
				end
			else
				if ( not groupState or groupState == 0 ) then
					enabledList[groupID] = 0;
				elseif ( groupState == 1 or groupState == 2 ) then
					enabledList[groupID]  = 1;
				end
			end
		end
	end
end

function LFGListRemoveCollapsedChildren(list, collapseStateList, hiddenByCollapseList)
	local currentPosition = 1;
	while ( currentPosition <= #list ) do
		local id = list[currentPosition];
		if ( not LFGIsIDHeader(id) and collapseStateList[id] ) then
			tinsert(hiddenByCollapseList, tremove(list, currentPosition));
		else
			currentPosition = currentPosition + 1;
		end
	end
end


--Reward frame functions
function LFGRewardsFrame_UpdateFrame(parentFrame, dungeonID, background)
	local parentName = parentFrame:GetName();
	
	parentFrame:Show();
	
	local holiday;
	local difficulty;
	local dungeonDescription;
	local textureFilename;
	local dungeonName, _,_,_,_,_,_,_,_,textureFilename,difficulty,_,dungeonDescription, isHoliday = GetLFGDungeonInfo(dungeonID);
	local isHeroic = difficulty > 0;
	local doneToday, moneyBase, moneyVar, experienceBase, experienceVar, numRewards = GetLFGDungeonRewards(dungeonID);
	local numRandoms = 4 - GetNumPartyMembers();
	local moneyAmount = moneyBase + moneyVar * numRandoms;
	local experienceGained = experienceBase + experienceVar * numRandoms;

	
	local backgroundTexture;
	
	local leaderChecked, tankChecked, healerChecked, damageChecked = LFDQueueFrame_GetRoles();
	
	--HACK
	if ( dungeonID == 341 ) then	--Trollpocalypse Heroic
		backgroundTexture = "Interface\\LFGFrame\\UI-LFG-BACKGROUND-TROLLPOCALYPSE";
	elseif ( textureFilename ~= "" ) then
		backgroundTexture = "Interface\\LFGFrame\\UI-LFG-HOLIDAY-BACKGROUND-"..textureFilename;
	elseif ( isHeroic ) then
		backgroundTexture = "Interface\\LFGFrame\\UI-LFG-BACKGROUND-HEROIC";
	else
		backgroundTexture = "Interface\\LFGFrame\\UI-LFG-BACKGROUND-QUESTPAPER";
	end
	background:SetTexture(backgroundTexture);
	
	local lastFrame = parentFrame.rewardsLabel;
	if ( isHoliday ) then
		if ( doneToday ) then
			parentFrame.rewardsDescription:SetText(LFD_HOLIDAY_REWARD_EXPLANATION2);
		else
			parentFrame.rewardsDescription:SetText(LFD_HOLIDAY_REWARD_EXPLANATION1);
		end
		parentFrame.title:SetText(dungeonName);
		parentFrame.description:SetText(dungeonDescription);
	else
		local numCompletions, isWeekly = LFGRewardsFrame_EstimateRemainingCompletions(dungeonID);
		if ( numCompletions <= 0 ) then
			parentFrame.rewardsDescription:SetText(LFD_RANDOM_REWARD_EXPLANATION2);
		elseif ( isWeekly ) then
			parentFrame.rewardsDescription:SetText(format(LFD_REWARD_DESCRIPTION_WEEKLY, numCompletions));
		else
			parentFrame.rewardsDescription:SetText(format(LFD_REWARD_DESCRIPTION_DAILY, numCompletions));
		end
		parentFrame.title:SetText(LFG_TYPE_RANDOM_DUNGEON);
		parentFrame.description:SetText(LFD_RANDOM_EXPLANATION);
	end
		
	local itemButtonIndex = 1;
	for i=1, numRewards do
		local name, texture, numItems = GetLFGDungeonRewardInfo(dungeonID, i);
		lastFrame = LFGRewardsFrame_SetItemButton(parentFrame, itemButtonIndex, i, name, texture, numItems, nil);
		itemButtonIndex = itemButtonIndex + 1;
	end
	
	for shortageIndex=1, LFG_ROLE_NUM_SHORTAGE_TYPES do
		local eligible, forTank, forHealer, forDamage, itemCount = GetLFGRoleShortageRewards(dungeonID, shortageIndex);
		if ( eligible and ((tankChecked and forTank) or (healerChecked and forHealer) or (damageChecked and forDamage)) ) then
			for rewardIndex=1, itemCount do
				local name, texture, numItems = GetLFGDungeonShortageRewardInfo(dungeonID, shortageIndex, rewardIndex);
				lastFrame = LFGRewardsFrame_SetItemButton(parentFrame, itemButtonIndex, rewardIndex, name, texture, numItems, shortageIndex, forTank, forHealer, forDamage);
				itemButtonIndex = itemButtonIndex + 1;
			end
		end
	end
	
	for i=itemButtonIndex, parentFrame.numRewardFrames do
		_G[parentName.."Item"..i]:Hide();
	end
	
	local totalRewards = itemButtonIndex - 1;
		
	if ( totalRewards > 0 or ((moneyVar == 0 and experienceVar == 0) and (moneyAmount > 0 or experienceGained > 0)) ) then
		parentFrame.rewardsLabel:Show();
		parentFrame.rewardsDescription:Show();
		lastFrame = parentFrame.rewardsDescription;
	else
		parentFrame.rewardsLabel:Hide();
		parentFrame.rewardsDescription:Hide();
	end
	
	if ( totalRewards > 0 ) then
		lastFrame = _G[parentName.."Item"..(totalRewards - mod(totalRewards+1, 2))];
	end
	
	if ( moneyVar > 0 or experienceVar > 0 ) then
		parentFrame.pugDescription:SetPoint("TOPLEFT", lastFrame, "BOTTOMLEFT", 0, -5);
		parentFrame.pugDescription:Show();
		lastFrame = parentFrame.pugDescription;
	else
		parentFrame.pugDescription:Hide();
	end
	
	if ( moneyAmount > 0 ) then
		MoneyFrame_Update(parentFrame.moneyFrame, moneyAmount);
		parentFrame.moneyLabel:SetPoint("TOPLEFT", lastFrame, "BOTTOMLEFT", 20, -10);
		parentFrame.moneyLabel:Show();
		parentFrame.moneyFrame:Show()
		
		parentFrame.xpLabel:SetPoint("TOPLEFT", lastFrame, "BOTTOMLEFT", 0, -5);
		
		lastFrame = parentFrame.moneyLabel;
	else
		parentFrame.moneyLabel:Hide();
		parentFrame.moneyFrame:Hide();
		
	end
	
	if ( experienceGained > 0 ) then
		parentFrame.xpAmount:SetText(experienceGained);
		
		if ( lastFrame == parentFrame.moneyLabel ) then
			parentFrame.xpLabel:SetPoint("TOPLEFT", lastFrame, "BOTTOMLEFT", 0, -5);
		else
			parentFrame.xpLabel:SetPoint("TOPLEFT", lastFrame, "BOTTOMLEFT", 20, -10);
		end
		parentFrame.xpLabel:Show();
		parentFrame.xpAmount:Show();
		
		lastFrame = parentFrame.xpLabel;
	else
		parentFrame.xpLabel:Hide();
		parentFrame.xpAmount:Hide();
	end
	
	if ( not isHoliday ) then
		parentFrame.randomList:Show();
	else
		parentFrame.randomList:Hide();
	end
	
	parentFrame.spacer:SetPoint("TOPLEFT", lastFrame, "BOTTOMLEFT", 0, -10);
end

function LFGRewardsFrame_SetItemButton(parentFrame, index, id, name, texture, numItems, shortageIndex, showTankIcon, showHealerIcon, showDamageIcon)
	local parentName = parentFrame:GetName();
	local frame = _G[parentName.."Item"..index];
	if ( not frame ) then
		frame = CreateFrame("Button", parentName.."Item"..index, _G[parentName], "LFGRewardsLootTemplate");
		parentFrame.numRewardFrames = index;
		if ( mod(index, 2) == 0 ) then
			frame:SetPoint("LEFT", parentName.."Item"..(index-1), "RIGHT", 0, 0);
		else
			frame:SetPoint("TOPLEFT", parentName.."Item"..(index-2), "BOTTOMLEFT", 0, -5);
		end
	end
	frame:SetID(id);
	
	_G[parentName.."Item"..index.."Name"]:SetText(name);
	SetItemButtonTexture(frame, texture);
	SetItemButtonCount(frame, numItems);
	frame.shortageIndex = shortageIndex;
	
	if ( shortageIndex ) then
		frame.shortageBorder:Show();
	else
		frame.shortageBorder:Hide();
	end
	
	local numRoles = (showTankIcon and 1 or 0) + (showHealerIcon and 1 or 0) + (showDamageIcon and 1 or 0);
	
	--Show role icons if this reward is specific to a role:
	frame.roleIcon1:Hide();
	frame.roleIcon2:Hide();
	
	if ( numRoles > 0 and numRoles < 3 ) then	--If we give it to all 3 roles, no reason to show icons.
		local roleIcon = frame.roleIcon1;
		if ( showTankIcon ) then
			roleIcon.texture:SetTexCoord(GetTexCoordsForRoleSmallCircle("TANK"));
			roleIcon.role = "TANK";
			roleIcon:Show();
			roleIcon = frame.roleIcon2;
		end
		if ( showHealerIcon ) then
			roleIcon.texture:SetTexCoord(GetTexCoordsForRoleSmallCircle("HEALER"));
			roleIcon.role = "HEALER";
			roleIcon:Show();
			roleIcon = frame.roleIcon2;
		end
		if ( showDamageIcon ) then
			roleIcon.texture:SetTexCoord(GetTexCoordsForRoleSmallCircle("DAMAGER"));
			roleIcon.role = "DAMAGER";
			roleIcon:Show();
			roleIcon = frame.roleIcon2;
		end
		
		if ( numRoles == 2 ) then
			frame.roleIcon1:SetPoint("LEFT", frame, "TOPLEFT", 1, -2);
		else
			frame.roleIcon1:SetPoint("LEFT", frame, "TOPLEFT", 10, -2);
		end
	end
	
	frame:Show();
	return frame;
end

function LFGRewardsFrame_EstimateRemainingCompletions(dungeonID)
	local currencyID, currencyQuantity, specificQuantity, specificLimit, overallQuantity, overallLimit, periodPurseQuantity, periodPurseLimit, isWeekly = GetLFGDungeonRewardCapInfo(dungeonID);
	if(not currencyID) then
		return 0, false;
	end

	local remainingAllotment = min(specificLimit - specificQuantity, overallLimit - overallQuantity);
	if ( periodPurseLimit ~= 0 ) then
		remainingAllotment = min(remainingAllotment, periodPurseLimit - periodPurseQuantity);
	end

	if (currencyQuantity == 0) then
		return 0, isWeekly;
	end

	return ceil(remainingAllotment / currencyQuantity), isWeekly;
end