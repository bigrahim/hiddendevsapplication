-- Connected Discord-GitHub
-- CoinRush: a round-based arena game. Players race to collect coins while sweeping hazards fling them away.
-- Structure: CONFIG -> helpers -> Stats / Hud / Coin / Hazard classes -> round flow -> main loop.

-- Services are fetched once and cached in locals; local lookups are faster than repeated game:GetService calls.
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")

-- All tunable numbers live in one table so balancing never requires touching logic.
local CONFIG = {
	GOAL = 15, -- coins needed to win early
	MAX_COINS = 12, -- cap on coins alive at once, keeps the arena readable
	HAZARD_COUNT = 4, -- number of sweeping hazards, one per lane
	ROUND_LENGTH = 60, -- seconds before the round ends by time
	INTERMISSION = 5, -- seconds of lobby/countdown between rounds
	RARE_CHANCE = 0.15, -- probability a spawned coin is a rare one
	RARE_VALUE = 3, -- points a rare coin is worth
	EDGE_MARGIN = 4, -- studs kept clear of the floor edge so nothing spawns on the lip
	KNOCKBACK = 80, -- launch speed applied to players hit by a hazard
	TICK = 0.25, -- how often the round loop refills coins and updates the HUD
}

-- Scene references: WaitForChild yields until replication finishes, avoiding nil errors at server start.
local arena = workspace:WaitForChild("arena")
local floor = arena:WaitForChild("floor")
local coinTemplate = ServerStorage:WaitForChild("coin")
local hazardTemplate = ServerStorage:WaitForChild("hazard")

-- One Random object is reused; creating a new one per call would waste allocations.
local rng = Random.new()

-- Shared round state. A single table avoids loose upvalues and makes the data flow obvious.
local state = {
	active = false, -- true only while a round is being played
	champion = nil, -- player who reached the goal first (nil if the timer decides)
	coins = {}, -- set of live Coin objects, keyed by object for O(1) removal
	coinCount = 0, -- tracked manually so we never have to iterate the set just to count it
	hazards = {}, -- array of live Hazard objects
}

-- Returns a world-space point on the floor at a given height above it.
-- Using floor.CFrame:PointToWorldSpace keeps this correct even if the floor is rotated or moved.
local function randomFloorPoint(height)
	local size = floor.Size
	local x = rng:NextNumber(-size.X / 2 + CONFIG.EDGE_MARGIN, size.X / 2 - CONFIG.EDGE_MARGIN)
	local z = rng:NextNumber(-size.Z / 2 + CONFIG.EDGE_MARGIN, size.Z / 2 - CONFIG.EDGE_MARGIN)
	return floor.CFrame:PointToWorldSpace(Vector3.new(x, size.Y / 2 + height, z))
end

-- ===================== Stats =====================
-- A plain namespace table: these functions never need per-instance state.
local Stats = {}

-- Creates the leaderstats folder; Roblox shows any IntValue inside it on the default leaderboard.
function Stats.create(player)
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats" -- this exact name is what the built-in leaderboard looks for
	for _, name in ipairs({ "Coins", "Wins", "Deaths" }) do
		local value = Instance.new("IntValue")
		value.Name = name
		value.Parent = folder
	end
	folder.Parent = player -- parent last so the leaderboard receives a fully built folder
end

-- Safe accessor: returns nil instead of erroring if the player is mid-leave or not set up yet.
function Stats.get(player, name)
	local folder = player:FindFirstChild("leaderstats")
	return folder and folder:FindFirstChild(name)
end

-- Adds to a stat if it exists; the single guard here spares every caller from nil checks.
function Stats.add(player, name, amount)
	local value = Stats.get(player, name)
	if value then
		value.Value += amount
	end
end

-- Resets every player's coin count at the start of a round.
function Stats.resetCoins()
	for _, player in ipairs(Players:GetPlayers()) do
		local value = Stats.get(player, "Coins")
		if value then
			value.Value = 0
		end
	end
end

-- Finds the player with the most coins; used as the tiebreak when time runs out.
function Stats.leader()
	local best, top = 0, nil
	for _, player in ipairs(Players:GetPlayers()) do
		local value = Stats.get(player, "Coins")
		if value and value.Value > best then
			best, top = value.Value, player
		end
	end
	return top
end

-- ===================== HUD =====================
-- Hud is a class: each player owns one instance holding their own ScreenGui labels.
local Hud = {}
Hud.__index = Hud -- failed lookups on an instance fall through to these methods
local huds = {} -- player -> Hud, so the server can broadcast and clean up per player

-- Builds one styled label; shared by both labels so styling stays identical.
local function makeLabel(parent, name, yOffset, height)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Size = UDim2.new(1, 0, 0, height) -- full width, fixed pixel height
	label.Position = UDim2.new(0, 0, 0, yOffset)
	label.BackgroundTransparency = 1 -- text only, no box over the gameplay
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0 -- black outline keeps text readable on any floor colour
	label.TextSize = height
	label.Font = Enum.Font.GothamBold
	label.Text = ""
	label.Parent = parent
	return label
end

-- Constructor: creates the gui and keeps direct references so updates never search by name.
function Hud.new(player)
	local self = setmetatable({}, Hud)
	local gui = Instance.new("ScreenGui")
	gui.Name = "hud"
	gui.ResetOnSpawn = false -- the HUD must survive respawns or it would flicker every death
	self.message = makeLabel(gui, "message", 10, 36)
	self.timer = makeLabel(gui, "timer", 50, 28)
	gui.Parent = player:WaitForChild("PlayerGui")
	self.gui = gui
	huds[player] = self
	return self
end

-- Updates both labels; seconds is optional so end-of-round messages can hide the timer.
function Hud:set(message, seconds)
	self.message.Text = message
	self.timer.Text = seconds and tostring(seconds) or ""
end

-- Sends the same message to every connected HUD.
local function broadcast(message, seconds)
	for _, hud in pairs(huds) do
		hud:set(message, seconds)
	end
end

-- ===================== Coin =====================
local Coin = {}
Coin.__index = Coin

-- Builds a coin; onCollect is injected so Coin never needs to know about game rules (loose coupling).
function Coin.new(position, isRare, onCollect)
	local self = setmetatable({}, Coin)
	self.value = isRare and CONFIG.RARE_VALUE or 1
	self.base = CFrame.new(position) -- resting pose; the bobbing animation is applied on top of it
	self.phase = rng:NextNumber(0, math.pi * 2) -- random offset so coins do not bob in lockstep
	self.taken = false -- guards against two players touching in the same frame
	self.part = coinTemplate:Clone()
	self.part.Anchored = true -- we drive the CFrame manually, so physics must not interfere
	if isRare then
		self.part.Color = Color3.fromRGB(80, 170, 255)
		self.part.Size *= 1.5
	end
	self.part.CFrame = self.base
	self.part.Parent = arena
	self.connection = self.part.Touched:Connect(function(hit)
		local player = Players:GetPlayerFromCharacter(hit.Parent) -- ignores non-character parts
		if player and not self.taken then
			self.taken = true
			onCollect(self, player)
		end
	end)
	return self
end

-- Per-frame animation: sine bob on Y combined with a spin, composed with CFrame multiplication.
function Coin:update(t)
	local bob = math.sin(t * 2 + self.phase) * 0.5
	self.part.CFrame = self.base * CFrame.new(0, bob, 0) * CFrame.Angles(0, t * 3 + self.phase, 0)
end

-- Disconnect before destroying so the event handler (and its closure) can be garbage collected.
function Coin:destroy()
	self.connection:Disconnect()
	self.part:Destroy()
end

-- ===================== Hazard =====================
local Hazard = {}
Hazard.__index = Hazard

-- Builds a hazard bar that sweeps across the floor along its own lane (index picks the lane).
function Hazard.new(index)
	local self = setmetatable({}, Hazard)
	local size = floor.Size
	self.part = hazardTemplate:Clone()
	self.part.Anchored = true
	-- Lanes are evenly spaced along Z; expressing the centre in floor-local space keeps rotation correct.
	local laneZ = -size.Z / 2 + index * size.Z / (CONFIG.HAZARD_COUNT + 1)
	self.center = floor.CFrame * CFrame.new(0, size.Y / 2 + self.part.Size.Y / 2, laneZ)
	self.amplitude = size.X / 2 - CONFIG.EDGE_MARGIN -- how far it travels from centre each way
	self.frequency = 0.4 + index * 0.15 -- deeper lanes sweep faster, scaling difficulty
	self.phase = rng:NextNumber(0, math.pi * 2)
	self.part.CFrame = self.center
	self.part.Parent = arena
	self.connection = self.part.Touched:Connect(function(hit)
		self:hit(hit)
	end)
	return self
end

-- Sweeps with a sine wave (smooth ease at both ends) and spins the bar for visual danger.
function Hazard:update(t)
	local offset = math.sin(t * self.frequency + self.phase) * self.amplitude
	self.part.CFrame = self.center * CFrame.new(offset, 0, 0) * CFrame.Angles(0, t * 2, 0)
end

-- Flings the touching character away from the hazard, then kills it for a ragdoll-style launch.
function Hazard:hit(hit)
	local character = hit.Parent
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or humanoid.Health <= 0 then
		return -- ignore scenery and already-dead characters so deaths are not double counted
	end
	local away = (root.Position - self.part.Position) * Vector3.new(1, 0, 1) -- flatten: push sideways only
	local direction = away.Magnitude > 0 and away.Unit or Vector3.xAxis -- fallback if exactly overlapping
	-- AssemblyLinearVelocity is the modern physics API; the upward component makes the launch arc.
	root.AssemblyLinearVelocity = direction * CONFIG.KNOCKBACK + Vector3.yAxis * CONFIG.KNOCKBACK * 0.5
	humanoid.Health = 0
end

function Hazard:destroy()
	self.connection:Disconnect()
	self.part:Destroy()
end

-- ===================== Round logic =====================
-- Called by a Coin when touched: awards points and ends the round if the goal is reached.
local function collectCoin(coin, player)
	if not state.active or not state.coins[coin] then
		return -- round already over or coin already removed
	end
	state.coins[coin] = nil
	state.coinCount -= 1
	Stats.add(player, "Coins", coin.value)
	coin:destroy()
	local total = Stats.get(player, "Coins")
	if total and total.Value >= CONFIG.GOAL then
		state.champion = player
		state.active = false -- the round loop sees this flag and exits on its next check
	end
end

-- Spawns coins until the cap is reached; the counter makes this O(missing) instead of O(all coins).
local function topUpCoins()
	while state.coinCount < CONFIG.MAX_COINS do
		local isRare = rng:NextNumber() < CONFIG.RARE_CHANCE
		local coin = Coin.new(randomFloorPoint(3), isRare, collectCoin)
		state.coins[coin] = true
		state.coinCount += 1
	end
end

-- Destroys every coin and hazard and resets the bookkeeping.
local function clearArena()
	for coin in pairs(state.coins) do
		coin:destroy()
	end
	for _, hazard in ipairs(state.hazards) do
		hazard:destroy()
	end
	state.coins, state.hazards, state.coinCount = {}, {}, 0
end

-- One Heartbeat connection drives all animation; this beats giving every object its own loop.
RunService.Heartbeat:Connect(function()
	local t = os.clock()
	for coin in pairs(state.coins) do
		coin:update(t)
	end
	for _, hazard in ipairs(state.hazards) do
		hazard:update(t)
	end
end)

-- Prepares a fresh round: clean arena, zero scores, respawn everyone, spawn hazards, then open play.
local function beginRound()
	clearArena()
	Stats.resetCoins()
	state.champion = nil
	for _, player in ipairs(Players:GetPlayers()) do
		player:LoadCharacter() -- puts everybody at spawn so nobody keeps a positional advantage
	end
	for index = 1, CONFIG.HAZARD_COUNT do
		table.insert(state.hazards, Hazard.new(index))
	end
	state.active = true -- flipped last so no coin can be collected mid-setup
end

-- Runs until the goal is hit or time expires; os.clock gives a real elapsed time regardless of task.wait drift.
local function runRound()
	local startTime = os.clock()
	while state.active do
		local remaining = CONFIG.ROUND_LENGTH - (os.clock() - startTime)
		if remaining <= 0 then
			break
		end
		broadcast("Collect " .. CONFIG.GOAL .. " coins!", math.ceil(remaining))
		topUpCoins()
		task.wait(CONFIG.TICK)
	end
	state.active = false -- covers the timeout path so late touches are ignored
end

-- Announces the result, credits the win, clears the arena, and holds for the intermission.
local function endRound()
	local winner = state.champion or Stats.leader() -- goal-reacher wins; otherwise highest score
	clearArena()
	if winner then
		Stats.add(winner, "Wins", 1)
		broadcast(winner.Name .. " wins!")
	else
		broadcast("Nobody won")
	end
	task.wait(CONFIG.INTERMISSION)
end

-- Blocks (without busy-waiting) until at least one player is present.
local function waitForPlayers()
	while #Players:GetPlayers() < 1 do
		broadcast("Waiting for players...")
		task.wait(1)
	end
end

-- Visible countdown so players know exactly when the round begins.
local function countdown()
	for seconds = CONFIG.INTERMISSION, 1, -1 do
		broadcast("Round starts in", seconds)
		task.wait(1)
	end
end

-- Per-player setup: stats, death tracking, and HUD.
local function setupPlayer(player)
	Stats.create(player)
	player.CharacterAdded:Connect(function(character)
		-- Humanoid.Died fires once per life; counting only during rounds keeps lobby deaths off the board.
		character:WaitForChild("Humanoid").Died:Connect(function()
			if state.active then
				Stats.add(player, "Deaths", 1)
			end
		end)
	end)
	Hud.new(player) -- last, because WaitForChild("PlayerGui") may yield
end

Players.PlayerAdded:Connect(setupPlayer)
Players.PlayerRemoving:Connect(function(player)
	huds[player] = nil -- drop the reference so broadcast skips them and memory is freed
end)
-- Players who joined before this script ran would otherwise be missed; task.spawn stops yields blocking the loop.
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(setupPlayer, player)
end

-- Main loop: lobby -> countdown -> play -> results, forever.
while true do
	waitForPlayers()
	countdown()
	beginRound()
	runRound()
	endRound()
end
