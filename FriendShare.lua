--------------------------------------------------------------------------
-- FriendShare.lua
--------------------------------------------------------------------------
--[[
FriendShare

author: Vimrasha <vimrasha@fastmail.fm>
ported to 7.3.5: implicit "this" replaced with explicit self (removed
from the client since Cataclysm), realm lookup switched from the
"realmName" CVar to GetRealmName(), and the first-login import no
longer depends solely on catching a single FRIENDLIST_UPDATE event
(see FriendShare_TryInitialize) since that event can arrive before -
or without ever being caused by - our own ShowFriends() call.

FriendShare synchronizes your friends lists across all your alts. No more jotting
down a character name and then logging into all your alts to add it. Just add it
once, and it will be added to your alts automatically when they log in.

Removing friends works the same way. If you remove a friend, then it will be
removed from your alts automatically the next time they log in.

When you log in, that alt is automatically added to your global friends list, and
will become a friend of all your other alts as they log in. This is really just
for auto name completion at the mailbox. If you manually remove an alt from your
friend list, it will not be re-added when you log that alt back in.

When you first start using FrendShare, the global friend list is initialized from
each alt as you log them in. So, just log all your alts in once and from that point
on they will all remain synchronized.

This all works without any user intervention.

Friends are stored on a per server, per faction (Horde or Alliance) basis.
]]--

local Saved_AddFriend = nil;
local Saved_RemoveFriend = nil;

local importedGlobalFriends = {};
local realmAndFaction = {};
local initialized = false;

-- Store current friends so that they are available when processing
-- the PLAYER_LEAVING_WORLD event.
local currentFriends = nil;

--[[ SavedVariables --]]
FriendShare_GlobalFriends = {};
FriendShare_RemovedFriends = {};
FriendShare_Alts = {};
FriendShare_AutoAlts = true;

--------------------------------------------------------------------------
-- Many private-server cores flood-protect the friend/ignore list
-- opcodes, silently dropping requests that arrive in a tight burst.
-- Importing a saved friends or ignores list means firing off AddFriend/
-- RemoveFriend/AddIgnore/DelIgnore calls for every name at once, which
-- is exactly that kind of burst - so instead of calling them directly,
-- everything goes through this queue and gets spaced out over time.
-- Shared by FriendShare and IgnoreShare (IgnoreShare.lua loads after
-- this file, per the .toc order).
--------------------------------------------------------------------------
local actionQueue = {};
local actionQueueRunning = false;
local actionQueueTotal = 0;
local actionQueueDone = 0;

function FriendShare_ProcessActionQueue()
	local action = tremove(actionQueue, 1);
	if ( not action ) then
		actionQueueRunning = false;
		if ( actionQueueTotal > 0 ) then
			FriendShare_ChatPrint( "FriendShare: Finished processing " .. actionQueueDone .. " friend/ignore change(s)." );
		end
		actionQueueTotal = 0;
		actionQueueDone = 0;
		return;
	end
	action.func( action.name );
	actionQueueDone = actionQueueDone + 1;
	C_Timer.After(0.5, FriendShare_ProcessActionQueue);
end

function FriendShare_QueueAction(func, name)
	tinsert(actionQueue, { func = func, name = name });
	actionQueueTotal = actionQueueTotal + 1;
	if ( not actionQueueRunning ) then
		actionQueueRunning = true;
		FriendShare_ProcessActionQueue();
	end
end


function FriendShare_ChatPrint(str)
	if ( DEFAULT_CHAT_FRAME ) then
		DEFAULT_CHAT_FRAME:AddMessage(str, 0.3, 0.3, 1.0);
	end
end

function FriendShare_OnLoad(self)

	-- register events
	self:RegisterEvent("PLAYER_ENTERING_WORLD");
	self:RegisterEvent("PLAYER_LEAVING_WORLD");

	SLASH_FRIENDSHARE1 = "/friendshare";
	SLASH_FRIENDSHARE2 = "/fs";
	SlashCmdList["FRIENDSHARE"] = function(msg)
		FriendShare_Command(msg);
	end

	-- Hook the Add/Remove friend handlers
	Saved_AddFriend = AddFriend;
	AddFriend = FriendShare_AddFriend;
	Saved_RemoveFriend = RemoveFriend;
	RemoveFriend = FriendShare_RemoveFriend;

	-- FriendShare_ChatPrint("FriendShare by Vimrasha loaded.");
end

function FriendShare_RealmAndFaction()
	local realmName = GetRealmName();
	local faction = UnitFactionGroup("player");
	return realmName .. "-" .. faction;
end

function FriendShare_CurrentFriends()
	local numFriends = GetNumFriends();
	local curFriends = {};

	-- Build a list of my current friends
	for i=1, numFriends do
		local name, level, class, area, connected = GetFriendInfo(i);
		if (name and name ~= UNKNOWN) then curFriends[name] = name; end
	end
	return curFriends;
end


function FriendShare_Command(command)
	local i,j, cmd, param = string.find(command, "^([^ ]+) (.+)$");
	if (not cmd) then cmd = command; end
	if (not cmd) then cmd = ""; end
	if (not param) then param = ""; end

	if ((cmd == "") or (cmd == "help")) then
		local  lineFormat = "  |cffffffff/friendshare %s|r - %s";
		FriendShare_ChatPrint( "Usage:" );
		FriendShare_ChatPrint(string.format(lineFormat, "<help>", "Print this message."));
		FriendShare_ChatPrint(string.format(lineFormat, "reset", "Reset the globals friend list to the character's current friends list."));
		FriendShare_ChatPrint(string.format(lineFormat, "import", "Import the global friends list."));
		FriendShare_ChatPrint(string.format(lineFormat, "alts", "Toggle auto adding of alts to your local friends list."));
		FriendShare_ChatPrint(string.format(lineFormat, "alts on|off", "Turn auto adding of alts to your local friends list on or off."));
		FriendShare_ChatPrint(string.format(lineFormat, "count", "Show how many names are saved vs. currently on this character's friends list."));
		FriendShare_ChatPrint(string.format(lineFormat, "listalts", "List the character names currently known as your alts."));
		FriendShare_ChatPrint(string.format(lineFormat, "addalt <name>", "Manually register <name> as one of your alts (for alts that never self-registered)."));
	end
	if (cmd == "reset" ) then
		FriendShare_ChatPrint( "FriendShare: Global friends list has been reset to this character's friends list." );
		-- Reset global friends list to match my friends
		FriendShare_GlobalFriends[realmAndFaction] = FriendShare_CurrentFriends();
		FriendShare_RemovedFriends[realmAndFaction] = {};
	end
	if (cmd == "import" ) then
		-- Import global friends list
		FriendShare_Import();
	end
	if (cmd == "count" ) then
		local globalCount, altCount, removedCount = 0, 0, 0;
		for i, name in pairs( FriendShare_GlobalFriends[realmAndFaction] or {} ) do globalCount = globalCount + 1; end
		for i, name in pairs( FriendShare_Alts[realmAndFaction] or {} ) do altCount = altCount + 1; end
		for i, name in pairs( FriendShare_RemovedFriends[realmAndFaction] or {} ) do removedCount = removedCount + 1; end
		FriendShare_ChatPrint( "FriendShare: " .. GetNumFriends() .. " friend(s) on this character, " ..
			globalCount .. " saved name(s), " .. altCount .. " known alt(s), " ..
			removedCount .. " name(s) marked removed." );
	end
	if (cmd == "listalts" ) then
		local names = "";
		for i, name in pairs( FriendShare_Alts[realmAndFaction] or {} ) do
			names = (names == "" and name) or (names .. ", " .. name);
		end
		if ( names == "" ) then
			FriendShare_ChatPrint( "FriendShare: No alts registered yet." );
		else
			FriendShare_ChatPrint( "FriendShare: Known alts - " .. names );
		end
	end
	if (cmd == "addalt" ) then
		if ( param == "" ) then
			FriendShare_ChatPrint( "FriendShare: Usage: /friendshare addalt <name>" );
		else
			local name = string.lower(param);
			name = string.gsub(name, "^%l", string.upper);
			if ( FriendShare_Alts[realmAndFaction][name] ) then
				FriendShare_ChatPrint( "FriendShare: " .. name .. " is already registered as an alt." );
			else
				FriendShare_Alts[realmAndFaction][name] = name;
				FriendShare_GlobalFriends[realmAndFaction][name] = nil;
				FriendShare_RemovedFriends[realmAndFaction][name] = nil;
				local curFriends = FriendShare_CurrentFriends();
				if ( name ~= UnitName("player") and not curFriends[name] ) then
					FriendShare_QueueAction(AddFriend, name);
				end
				FriendShare_ChatPrint( "FriendShare: " .. name .. " registered as an alt and queued to be added." );
			end
		end
	end
	if (cmd == "alts" ) then
		local autoAlts = FriendShare_AutoAlts;
		if ( param == "" ) then
			FriendShare_AutoAlts = not FriendShare_AutoAlts;
			if ( FriendShare_AutoAlts ) then
				FriendShare_ChatPrint( "FriendShare: Auto adding of alts toggled on." );
			else
				FriendShare_ChatPrint( "FriendShare: Auto adding of alts toggled off." );
			end
		elseif ( param == "on" ) then
			FriendShare_AutoAlts = true;
			FriendShare_ChatPrint( "FriendShare: Auto adding of alts turned on." );
		elseif ( param == "off" ) then
			FriendShare_AutoAlts = false;
			FriendShare_ChatPrint( "FriendShare: Auto adding of alts turned off." );
		else
			FriendShare_ChatPrint( "FriendShare: Unknown parameter to '/FriendShare alts'." );
		end

		-- If AutoAlts setting changed, then process the alts list
		if ( autoAlts ~= FriendShare_AutoAlts ) then
			local currentFriends = FriendShare_CurrentFriends();
			FriendShare_ProcessAlts( currentFriends );
		end

	end
end

function FriendShare_Import()
	local curFriends = FriendShare_CurrentFriends();
	local player = UnitName("player");
	local numFriends = GetNumFriends();
	local globalFriends = FriendShare_GlobalFriends[realmAndFaction];
	local globalCount = 0;
	for i, name in pairs( globalFriends ) do
		globalCount = globalCount + 1;
	end

	-- Clear the list of importedGlobalFriends before trying to import again.
	importedGlobalFriends = {};

	-- Remove local friends that have been removed globaly
	local globalRemoves = FriendShare_RemovedFriends[realmAndFaction];
	for i, name in pairs( globalRemoves ) do
		if ( name ~= player and curFriends[name] and
			not FriendShare_Alts[realmAndFaction][name] )
		then
			FriendShare_QueueAction(RemoveFriend, name);
			numFriends = numFriends - 1;
			curFriends[name] = nil;
		end
	end

	-- Add global friends that are not currently in local friends list
	-- Make a copy of the table as we will modify the original in the loop
	local queuedToAdd = 0;
	local skippedForCap = 0;
	for i, name in pairs( globalFriends ) do
		if ( name ~= player and not curFriends[name] and
			not FriendShare_RemovedFriends[realmAndFaction][name] and
			not FriendShare_Alts[realmAndFaction][name] )
		then
			-- WoW caps a character at 50 friends. Once we estimate we're at
			-- that cap, stop queuing AddFriend for the rest - the server
			-- would just reject them anyway. They stay in the saved list
			-- (not marked imported) so they'll be retried automatically on
			-- a future login if room ever opens up.
			if ( numFriends < 50 ) then
				-- If this charater still exists, it will be added back to the global list
				-- when processing the generated FRIENDLIST_UPDATE event.
				FriendShare_GlobalFriends[realmAndFaction][name] = nil;
				importedGlobalFriends[name] = name;
				-- numFriends is just a guess since we don't know if AddFriend will succeed or not.
				numFriends = numFriends + 1;
				queuedToAdd = queuedToAdd + 1;
				FriendShare_QueueAction(AddFriend, name);
			else
				skippedForCap = skippedForCap + 1;
			end
		end
	end

	FriendShare_ProcessAlts( curFriends, numFriends );
	FriendShare_UpdateGlobalFriends( curFriends );

	FriendShare_ChatPrint( "FriendShare: Your saved friends list has " .. globalCount ..
		" name(s) total; queuing " .. queuedToAdd .. " to be added to this character." );
	if ( skippedForCap > 0 ) then
		FriendShare_ChatPrint( "FriendShare: Warning! " .. skippedForCap ..
			" name(s) can't be added - you're at (or will hit) the 50 friend limit." );
	end
end


function FriendShare_ProcessAlts( curFriends, startingCount )
	local player = UnitName( "player" );
	local numFriends = startingCount or GetNumFriends();
	for i, name in pairs( FriendShare_Alts[realmAndFaction] ) do
		local name = FriendShare_Alts[realmAndFaction][i]
		if ( FriendShare_AutoAlts ) then
			-- AutoAlts on - add alts that are not currently friends
			if ( name ~= player and not curFriends[name] ) then
				if ( numFriends < 50 ) then
					FriendShare_ChatPrint( "FriendShare: Auto adding alt " .. name .. " to local friends list." );
					numFriends = numFriends + 1;
					FriendShare_QueueAction(AddFriend, name);
				end
			end
		else
			-- AutoAlts off - remove alts that are currently friends
			if ( name ~= player and curFriends[name] ) then
				FriendShare_ChatPrint( "FriendShare: Auto removing alt " .. name .. " from local friends list." );
				numFriends = numFriends - 1;
				FriendShare_QueueAction(RemoveFriend, name);
			end
		end
		-- Alts are not to be stored in the normal lists
		FriendShare_GlobalFriends[realmAndFaction][name] = nil;
		FriendShare_RemovedFriends[realmAndFaction][name] = nil;
	end
	-- Ensure this toon is in the alt list
	if ( not FriendShare_Alts[realmAndFaction][player] ) then
		FriendShare_ChatPrint( "Adding this toon to your global alt list." );
		FriendShare_Alts[realmAndFaction][player] = player;
	end
end

-- Keep a record of current friends for use when handling PLAYER_LEAVING_WORLD.
local savedCurrentFriends = {};
local savedPlayerName;

-- Runs the one-time "sync this alt up with the global friend/ignore
-- lists" import. Guarded by `initialized` so it only ever runs once per
-- session, however it gets triggered.
local function FriendShare_TryInitialize()
	if ( initialized ) then return; end
	initialized = true;
	-- Import the global friends list.
	FriendShare_Import();
	savedCurrentFriends = FriendShare_CurrentFriends();
	-- Import the global ignore list.
	IgnoreShare_Import();
end

function FriendShare_OnEvent(self, event, ...)

	if ( event == "PLAYER_ENTERING_WORLD" ) then
		-- Only do this stuff once.
		self:UnregisterEvent("PLAYER_ENTERING_WORLD");

		-- Can't init these values until the player is in the world...
		realmAndFaction = FriendShare_RealmAndFaction();
		savedPlayerName = UnitName( "player" );


		if ( not FriendShare_GlobalFriends[realmAndFaction] ) then
			FriendShare_GlobalFriends[realmAndFaction] = {};
		end
		-- A client timing bug could have placed this bogus value in the list
		FriendShare_GlobalFriends[realmAndFaction][UNKNOWN] = nil;

		if ( not FriendShare_RemovedFriends[realmAndFaction] ) then
			FriendShare_RemovedFriends[realmAndFaction] = {};
		end
		-- A client timing bug could have placed this bogus value in the list
		FriendShare_RemovedFriends[realmAndFaction][UNKNOWN] = nil;


		if ( not FriendShare_Alts[realmAndFaction] ) then
			FriendShare_Alts[realmAndFaction] = {};
		end

		-- Player must be in the world before we start listening to these events
		-- so that the player's faction is know and its list of friends
		-- has been loaded.
		self:RegisterEvent("FRIENDLIST_UPDATE");

		-- Ask the server to (re)send the friend list. On some servers the
		-- list is already pushed to the client before this event fires -
		-- or before we've registered to hear about it - so a
		-- FRIENDLIST_UPDATE caused by our own ShowFriends() call isn't
		-- guaranteed. Fall back to importing directly a couple of
		-- seconds later if we still haven't seen one by then.
		ShowFriends();
		C_Timer.After(2, FriendShare_TryInitialize);
		C_Timer.After(6, FriendShare_TryInitialize);
	end

	if ( event == "FRIENDLIST_UPDATE" ) then
		if ( not initialized ) then
			FriendShare_TryInitialize();
		else
			savedCurrentFriends = FriendShare_CurrentFriends();
			FriendShare_UpdateGlobalFriends( savedCurrentFriends );
		end
	end

	if ( event == "PLAYER_LEAVING_WORLD" ) then
		-- Only do this stuff once.
		self:UnregisterEvent("PLAYER_LEAVING_WORLD");

		-- Imported global friends that are not current friends either
		-- had errors on import (player not found) or have been deleted.
		-- Either way they should be removed from the global list.
		for i, name in pairs( importedGlobalFriends ) do
			if ( not savedCurrentFriends[name] and not FriendShare_Alts[realmAndFaction][name] ) then
				FriendShare_GlobalFriends[realmAndFaction][name] = nil;
			end
		end

		-- Check for deleted alts
		if ( FriendShare_AutoAlts ) then
			for i, name in pairs( FriendShare_Alts[realmAndFaction] ) do
				if ( not (name == savedPlayerName) and not savedCurrentFriends[name] ) then
					FriendShare_ChatPrint( "FriendShare: " .. name .. " appears to be a deleted alt." );
					FriendShare_ChatPrint( "FriendShare: Removing " .. name .. " from global alt list." );
					FriendShare_Alts[realmAndFaction][name] = nil;
				end
			end
		end

	end
end

-- Ensure all friends in the given list are in the global friends list
function FriendShare_UpdateGlobalFriends(friendsList)
	for i, name in pairs( friendsList ) do
		if ( not FriendShare_GlobalFriends[realmAndFaction][name] and
			not FriendShare_RemovedFriends[realmAndFaction][name] and
			not FriendShare_Alts[realmAndFaction][name] )
		then
			FriendShare_ChatPrint( "FriendShare: Adding global friend " .. name );
			FriendShare_GlobalFriends[realmAndFaction][name] = name;
		end
	end
end

function FriendShare_AddFriend(name)
	if ( not name ) then return; end

	-- Ensure the first letter and only the first letter is capitalized
	name = string.lower(name);
	name = string.gsub(name, "^%l", string.upper);

	Saved_AddFriend(name);
	-- Friend will be added to the global list on next FRIENDLIST_UPDATE event if needed
	FriendShare_RemovedFriends[realmAndFaction][name] = nil;
end

function FriendShare_RemoveFriend(nameOrIndex)
	local name, level, class, area, connected;
	if ( type(nameOrIndex) == "string" ) then
		name = nameOrIndex;
	else
		name, level, class, area, connected = GetFriendInfo(nameOrIndex);
	end

	if ( not name ) then return; end

	-- Ensure the first letter and only the first letter is capitalized
	name = string.lower(name);
	name = string.gsub(name, "^%l", string.upper);

	Saved_RemoveFriend(name);
	FriendShare_GlobalFriends[realmAndFaction][name] = nil;
	-- Don't put alts on the removed friends list
	if ( not FriendShare_Alts[name] ) then
		FriendShare_RemovedFriends[realmAndFaction][name] = name;
	end
end
