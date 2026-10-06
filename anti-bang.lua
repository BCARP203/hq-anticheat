local Players = game:GetService("Players")

local server = script.Parent.Parent
local Config = require(server.Parent.shared.Config)
local Session = require(server.core.Session)
local Health = require(server.core.Health)
local Enforcement = require(server.core.Enforcement)
local Log = require(server.core.Log)

local BangGuard = {}

local blocked = {}
local hookedAnimators = setmetatable({}, { __mode = "k" })
local streaks = {}

for _, id in ipairs(Config.BangAnimationIds) do
	blocked[tostring(id)] = true
end

function BangGuard.AnimationNumber(animationId)
	if type(animationId) ~= "string" then return nil end
	return string.match(animationId, "(%d+)%s*$")
end

function BangGuard.IsBlocked(track)
	local ok, id = pcall(function()
		return track.Animation and track.Animation.AnimationId
	end)
	if not ok then return false end
	local number = BangGuard.AnimationNumber(id)
	return number ~= nil and blocked[number] == true, number
end

local function flagTrack(player, track)
	local isBlocked, number = BangGuard.IsBlocked(track)
	if not isBlocked then return end
	Enforcement.Report(player, "BangAnimation", string.format("Played bang animation %s at speed %.1f", tostring(number), track.Speed))
end

local function hookAnimator(player, animator)
	if hookedAnimators[animator] then return end
	hookedAnimators[animator] = true
	animator.AnimationPlayed:Connect(function(track)
		if player.Character and animator:IsDescendantOf(player.Character) then
			flagTrack(player, track)
		end
	end)
end

local function hookCharacter(player, character)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid then return end
	local animator = humanoid:FindFirstChildOfClass("Animator") or humanoid:WaitForChild("Animator", 10)
	if animator then
		hookAnimator(player, animator)
	end
	humanoid.ChildAdded:Connect(function(child)
		if child:IsA("Animator") then
			hookAnimator(player, child)
		end
	end)
end

local function onPlayer(player)
	player.CharacterAdded:Connect(function(character)
		task.spawn(hookCharacter, player, character)
	end)
	if player.Character then
		task.spawn(hookCharacter, player, player.Character)
	end
end

local function torsoOf(character)
	return character:FindFirstChild("Torso")
		or character:FindFirstChild("UpperTorso")
		or character:FindFirstChild("HumanoidRootPart")
end

local function alive(character)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function canJudge(player)
	if Session.IsLocked(player) then return false end
	if Session.IsAdmin(player) then return false end
	if Session.IsExempt(player) then return false end
	if Session.IsSeated(player) then return false end
	return true
end

function BangGuard.GlueSample(attackerRoot, targetTorso)
	local rel = targetTorso.CFrame:PointToObjectSpace(attackerRoot.Position)
	local tol = Config.BangGlueTolerance
	if math.abs(rel.X) > tol then return false end
	if math.abs(rel.Y) > tol + 0.6 then return false end
	if math.abs(rel.Z - Config.BangGlueOffsetZ) > tol then return false end
	local facing = attackerRoot.CFrame.LookVector:Dot(targetTorso.CFrame.LookVector)
	return facing >= Config.BangGlueFacingDot
end

local function scanTracks()
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
		if animator then
			hookAnimator(player, animator)
			local ok, tracks = pcall(function()
				return animator:GetPlayingAnimationTracks()
			end)
			if ok then
				for _, track in ipairs(tracks) do
					flagTrack(player, track)
				end
			end
		end
	end
end

local function scanGlue()
	if Health.IsDegraded() then return end
	local list = Players:GetPlayers()
	for _, attacker in ipairs(list) do
		local aChar = attacker.Character
		local aRoot = aChar and aChar:FindFirstChild("HumanoidRootPart")
		local hit = nil

		if aRoot and alive(aChar) and canJudge(attacker) then
			for _, target in ipairs(list) do
				if target ~= attacker then
					local tChar = target.Character
					local tTorso = tChar and torsoOf(tChar)
					if tTorso and alive(tChar) and not Session.IsExempt(target) and not Session.IsSeated(target)
						and (tTorso.Position - aRoot.Position).Magnitude <= Config.BangGlueMaxRange
						and BangGuard.GlueSample(aRoot, tTorso)
					then
						hit = target
						break
					end
				end
			end
		end

		local entry = streaks[attacker]
		if hit then
			if not entry or entry.target ~= hit then
				entry = { target = hit, count = 0 }
				streaks[attacker] = entry
			end
			entry.count += 1
			if entry.count >= Config.BangGlueSamples then
				Log.Event("BangGlue", attacker.Name, "glued behind " .. hit.Name)
				Enforcement.Report(attacker, "BangGlue", string.format("Locked %.1f studs behind %s's torso, same facing, for %.1fs",
					Config.BangGlueOffsetZ, hit.Name, entry.count * Config.BangGlueInterval))
				entry.count = 0
			end
		elseif entry then
			entry.count = math.max(0, entry.count - 2)
			if entry.count == 0 then
				streaks[attacker] = nil
			end
		end
	end
end

function BangGuard.Start()
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		streaks[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(Config.BangScanInterval)
			pcall(scanTracks)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(Config.BangGlueInterval)
			pcall(scanGlue)
		end
	end)
end

return BangGuard
