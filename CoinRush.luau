-- Connected Discord-GitHub
-- CoinRush: grab coins, dodge the sweepers

local players = game:GetService("Players")
local storage = game:GetService("ServerStorage")
local runservice = game:GetService("RunService")

local config = {
	goal = 15, -- coins needed to win early
	cap = 12, -- max coins on the floor
	lanes = 4, -- one hazard per lane
	duration = 60,
	intermission = 5,
	rarity = 0.15, -- chance a coin is rare
	bonus = 3, -- rare coin value
	margin = 4, -- keep spawns away from the edge
	knockback = 80,
	tick = 0.25,
}

local arena = workspace:WaitForChild("arena")
local floor = arena:WaitForChild("floor")
local cointemplate = storage:WaitForChild("coin")
local hazardtemplate = storage:WaitForChild("hazard")

local rng = Random.new()

local state = {
	active = false,
	champion = nil,
	coins = {},
	count = 0,
	hazards = {},
}

local function randompoint(height)
	local size = floor.Size
	local x = rng:NextNumber(-size.X / 2 + config.margin, size.X / 2 - config.margin)
	local z = rng:NextNumber(-size.Z / 2 + config.margin, size.Z / 2 - config.margin)
	return floor.CFrame:PointToWorldSpace(Vector3.new(x, size.Y / 2 + height, z))
end

-- scores

local scores = {}

function scores.create(player)
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"
	for _, name in ipairs({ "Coins", "Wins", "Deaths" }) do
		local value = Instance.new("IntValue")
		value.Name = name
		value.Parent = folder
	end
	folder.Parent = player
end

function scores.get(player, name)
	local folder = player:FindFirstChild("leaderstats")
	return folder and folder:FindFirstChild(name)
end

function scores.add(player, name, amount)
	local value = scores.get(player, name)
	if value then
		value.Value += amount
	end
end

function scores.reset()
	for _, player in ipairs(players:GetPlayers()) do
		local value = scores.get(player, "Coins")
		if value then
			value.Value = 0
		end
	end
end

function scores.leader()
	local best, top = 0, nil
	for _, player in ipairs(players:GetPlayers()) do
		local value = scores.get(player, "Coins")
		if value and value.Value > best then
			best, top = value.Value, player
		end
	end
	return top
end

-- hud

local hud = {}
hud.__index = hud
local huds = {}

local function newlabel(parent, name, y, height)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Size = UDim2.new(1, 0, 0, height)
	label.Position = UDim2.new(0, 0, 0, y)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0
	label.TextSize = height
	label.Font = Enum.Font.GothamBold
	label.Text = ""
	label.Parent = parent
	return label
end

function hud.new(player)
	local self = setmetatable({}, hud)
	local gui = Instance.new("ScreenGui")
	gui.Name = "hud"
	gui.ResetOnSpawn = false
	self.message = newlabel(gui, "message", 10, 36)
	self.timer = newlabel(gui, "timer", 50, 28)
	gui.Parent = player:WaitForChild("PlayerGui")
	self.gui = gui
	huds[player] = self
	return self
end

function hud:set(message, seconds)
	self.message.Text = message
	self.timer.Text = seconds and tostring(seconds) or ""
end

local function broadcast(message, seconds)
	for _, h in pairs(huds) do
		h:set(message, seconds)
	end
end

-- coin

local coin = {}
coin.__index = coin

function coin.new(position, rare, oncollect)
	local self = setmetatable({}, coin)
	self.value = rare and config.bonus or 1
	self.base = CFrame.new(position)
	self.phase = rng:NextNumber(0, math.pi * 2) -- so coins don't bob in sync
	self.taken = false
	self.part = cointemplate:Clone()
	self.part.Anchored = true
	if rare then
		self.part.Color = Color3.fromRGB(80, 170, 255)
		self.part.Size *= 1.5
	end
	self.part.CFrame = self.base
	self.part.Parent = arena
	self.connection = self.part.Touched:Connect(function(hit)
		local player = players:GetPlayerFromCharacter(hit.Parent)
		if player and not self.taken then
			self.taken = true
			oncollect(self, player)
		end
	end)
	return self
end

function coin:update(t)
	local bob = math.sin(t * 2 + self.phase) * 0.5
	self.part.CFrame = self.base * CFrame.new(0, bob, 0) * CFrame.Angles(0, t * 3 + self.phase, 0)
end

function coin:destroy()
	self.connection:Disconnect()
	self.part:Destroy()
end

-- hazard

local hazard = {}
hazard.__index = hazard

function hazard.new(index)
	local self = setmetatable({}, hazard)
	local size = floor.Size
	self.part = hazardtemplate:Clone()
	self.part.Anchored = true
	local lane = -size.Z / 2 + index * size.Z / (config.lanes + 1)
	self.center = floor.CFrame * CFrame.new(0, size.Y / 2 + self.part.Size.Y / 2, lane)
	self.amplitude = size.X / 2 - config.margin
	self.frequency = 0.4 + index * 0.15 -- later lanes move faster
	self.phase = rng:NextNumber(0, math.pi * 2)
	self.part.CFrame = self.center
	self.part.Parent = arena
	self.connection = self.part.Touched:Connect(function(hit)
		self:hit(hit)
	end)
	return self
end

function hazard:update(t)
	local offset = math.sin(t * self.frequency + self.phase) * self.amplitude
	self.part.CFrame = self.center * CFrame.new(offset, 0, 0) * CFrame.Angles(0, t * 2, 0)
end

function hazard:hit(hit)
	local character = hit.Parent
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or humanoid.Health <= 0 then
		return
	end
	local away = (root.Position - self.part.Position) * Vector3.new(1, 0, 1)
	local direction = away.Magnitude > 0 and away.Unit or Vector3.xAxis
	root.AssemblyLinearVelocity = direction * config.knockback + Vector3.yAxis * config.knockback * 0.5
	humanoid.Health = 0
end

function hazard:destroy()
	self.connection:Disconnect()
	self.part:Destroy()
end

-- rounds

local function collect(c, player)
	if not state.active or not state.coins[c] then
		return
	end
	state.coins[c] = nil
	state.count -= 1
	scores.add(player, "Coins", c.value)
	c:destroy()
	local total = scores.get(player, "Coins")
	if total and total.Value >= config.goal then
		state.champion = player
		state.active = false
	end
end

local function refill()
	while state.count < config.cap do
		local rare = rng:NextNumber() < config.rarity
		local c = coin.new(randompoint(3), rare, collect)
		state.coins[c] = true
		state.count += 1
	end
end

local function clear()
	for c in pairs(state.coins) do
		c:destroy()
	end
	for _, h in ipairs(state.hazards) do
		h:destroy()
	end
	state.coins, state.hazards, state.count = {}, {}, 0
end

runservice.Heartbeat:Connect(function()
	local t = os.clock()
	for c in pairs(state.coins) do
		c:update(t)
	end
	for _, h in ipairs(state.hazards) do
		h:update(t)
	end
end)

local function startround()
	clear()
	scores.reset()
	state.champion = nil
	for _, player in ipairs(players:GetPlayers()) do
		player:LoadCharacter()
	end
	for index = 1, config.lanes do
		table.insert(state.hazards, hazard.new(index))
	end
	state.active = true -- set last so nothing gets collected during setup
end

local function playround()
	local start = os.clock()
	while state.active do
		local remaining = config.duration - (os.clock() - start)
		if remaining <= 0 then
			break
		end
		broadcast("Collect " .. config.goal .. " coins!", math.ceil(remaining))
		refill()
		task.wait(config.tick)
	end
	state.active = false
end

local function endround()
	local winner = state.champion or scores.leader()
	clear()
	if winner then
		scores.add(winner, "Wins", 1)
		broadcast(winner.Name .. " wins!")
	else
		broadcast("Nobody won")
	end
	task.wait(config.intermission)
end

local function waitforplayers()
	while #players:GetPlayers() < 1 do
		broadcast("Waiting for players...")
		task.wait(1)
	end
end

local function countdown()
	for seconds = config.intermission, 1, -1 do
		broadcast("Round starts in", seconds)
		task.wait(1)
	end
end

local function setup(player)
	scores.create(player)
	player.CharacterAdded:Connect(function(character)
		character:WaitForChild("Humanoid").Died:Connect(function()
			if state.active then -- don't count lobby deaths
				scores.add(player, "Deaths", 1)
			end
		end)
	end)
	hud.new(player)
end

players.PlayerAdded:Connect(setup)
players.PlayerRemoving:Connect(function(player)
	huds[player] = nil
end)

-- catch anyone who joined before this ran
for _, player in ipairs(players:GetPlayers()) do
	task.spawn(setup, player)
end

while true do
	waitforplayers()
	countdown()
	startround()
	playround()
	endround()
end
