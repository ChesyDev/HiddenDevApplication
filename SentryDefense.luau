-- Connected Discord-GitHub, Discord: chesy_, Roblox: Chesy_Dev
--[[
	SentryDefense (Script in ServerScriptService)

	Server-authoritative sentry turret system:
	  Turrets are Models tagged "SentryTurret"; drone flight paths are Parts tagged "DroneSpawn".
	  Turrets lead moving targets (quadratic intercept) and compensate for gravity (ballistic launch angle).
	  Projectiles are simulated manually with kinematic equations + raycasts, pooled, and moved with BulkMoveTo.
	  Drones and player characters share one "Targetable" interface so turrets treat them identically.
	  Everything is updated from a single Heartbeat connection to keep per-frame overhead predictable.
]]

local Players = game:GetService("Players") -- PlayerAdded/CharacterAdded let player characters register as targets
local RunService = game:GetService("RunService") -- Heartbeat drives one shared simulation loop instead of one loop per object
local CollectionService = game:GetService("CollectionService") -- tags let a builder place turrets/spawns in Studio without touching code
local TweenService = game:GetService("TweenService") -- only used for short cosmetic animations (health bar, impact flash)
local Debris = game:GetService("Debris") -- schedules removal of cosmetic parts without yielding the main loop

local CONFIG = table.freeze({ -- frozen so no code path can accidentally mutate tuning values at runtime
	TURRET_TAG = "SentryTurret", -- CollectionService tag marking a Model as a turret
	DRONE_SPAWN_TAG = "DroneSpawn", -- CollectionService tag marking a Part as the centre of a drone flight path
	SCAN_INTERVAL = 0.25, -- target search is throttled because raycasts cost far more than rotating a head
	TURN_RATE = math.rad(240), -- max angular speed (rad/s) so turrets visibly swing instead of snapping
	MIN_PITCH = math.rad(-20), -- lower gimbal limit keeps the barrel from clipping into its own base
	MAX_PITCH = math.rad(75), -- upper gimbal limit mimics a real mechanical mount
	FIRE_ALIGNMENT = math.cos(math.rad(4)), -- dot-product threshold: fire only when barrel is within 4 degrees of the solution
	IDLE_SWEEP_RATE = math.rad(30), -- idle turrets slowly sweep so they read as "searching"
	SOLVER_ITERATIONS = 3, -- refinement passes that fold the arc's extra flight time back into the lead
	PROJECTILE_LIFETIME = 3, -- seconds before an un-hit projectile is recycled
	PROJECTILE_SIZE = Vector3.new(0.3, 0.3, 1.6), -- elongated so orientation along velocity is visible
	PROJECTILE_COLOR = Color3.fromRGB(255, 170, 40), -- warm tracer colour
	PARK_CFRAME = CFrame.new(0, 1e4, 0), -- pooled parts are parked far above the map instead of being destroyed
	DRONE_MAX_HEALTH = 100, -- hit points of each target drone
	DRONE_RESPAWN_TIME = 4, -- seconds before a destroyed drone is rebuilt
	DRONE_SIZE = 4, -- diameter of the drone sphere in studs
	DRONE_COLOR = Color3.fromRGB(255, 0, 0), -- cool colour contrasts with tracers
})

type MaidTask = RBXScriptConnection | Instance | () -> () -- every kind of resource the Maid knows how to release

type Targetable = { -- structural interface shared by Drone and CharacterTarget so turrets never care which they hold
	Kind: string, -- "Drone" or "Player", lets turrets filter what they may engage
	GetPosition: (self: any) -> Vector3, -- world point to aim at
	GetVelocity: (self: any) -> Vector3, -- studs/s, needed for lead prediction
	IsAlive: (self: any) -> boolean, -- stale targets are dropped when this turns false
	ApplyDamage: (self: any, amount: number) -> boolean, -- returns true when the hit was lethal so the shooter can be credited
}

type Projectile = { -- plain record: projectiles are pure data, so no metatable/method overhead per bullet
	Part: BasePart, -- pooled visual
	Position: Vector3, -- simulated position (source of truth, the part only mirrors it)
	Velocity: Vector3, -- current velocity, integrated with gravity each step
	Age: number, -- seconds alive, compared with PROJECTILE_LIFETIME
	Damage: number, -- copied at fire time so later attribute edits don't affect bullets in flight
	Source: any, -- the Turret that fired it, credited on kills
}

local targetRegistry: { [Instance]: Targetable } = {} -- root Instance (drone part / character model) -> target object, O(1) hit lookup
local turrets: { [Model]: any } = {} -- live Turret objects keyed by their Model
local drones: { [BasePart]: any } = {} -- live Drone objects keyed by their spawn Part
local activeProjectiles: { Projectile } = {} -- array (not dictionary) so swap-remove keeps iteration cheap
local projectilePool: { BasePart } = {} -- recycled projectile parts; avoids Instance.new/Destroy churn every shot
local moveParts: { BasePart } = {} -- reused scratch buffer for BulkMoveTo, cleared not reallocated each frame
local moveCFrames: { CFrame } = {} -- parallel buffer of target CFrames for BulkMoveTo

local projectileFolder = Instance.new("Folder") -- one container so all projectiles/effects can be excluded from raycasts in one entry
projectileFolder.Name = "SentryProjectiles" -- readable name in Explorer while debugging
projectileFolder.Parent = workspace -- must be in Workspace for parts to render and replicate

local droneFolder = Instance.new("Folder") -- keeps drone bodies grouped instead of cluttering Workspace root
droneFolder.Name = "SentryDrones" -- readable name in Explorer
droneFolder.Parent = workspace -- drones must be in Workspace to be hit by raycasts

local worldParams = RaycastParams.new() -- shared params object; constructing one per raycast would allocate every frame
worldParams.FilterType = Enum.RaycastFilterType.Exclude -- everything is hittable except what we list
worldParams.IgnoreWater = true -- bullets and sight lines should pass through terrain water

local function rebuildRaycastFilter(): () -- the exclude list changes only when turrets appear/disappear, so rebuild lazily
	local ignore: { Instance } = { projectileFolder } -- bullets must never hit each other or their own impact flashes
	for model in turrets do -- turrets ignore all turret bodies so they never block their own (or allied) shots
		table.insert(ignore, model) -- whole model is excluded, including head and barrel descendants
	end
	worldParams.FilterDescendantsInstances = ignore -- assigning the property is required; mutating the old table does nothing
end

local function readNumber(instance: Instance, name: string, default: number): number -- attributes are untyped, so validate before use
	local value = instance:GetAttribute(name) -- returns nil if the builder never set it
	return if typeof(value) == "number" then value else default -- typeof guards against a string typed into the attribute
end

local function wrapAngle(angle: number): number -- maps any angle into [-pi, pi) so turrets always turn the short way round
	return (angle + math.pi) % (2 * math.pi) - math.pi -- Luau's % is floored, so negatives wrap correctly
end

local function stepAngle(current: number, target: number, maxStep: number): number -- rate-limited rotation towards target
	local delta = wrapAngle(target - current) -- shortest signed difference, avoids the 350-degree spin
	return current + math.clamp(delta, -maxStep, maxStep) -- clamp gives constant angular speed independent of distance
end

local function resolveTarget(instance: Instance): Targetable? -- maps whatever a ray hit back to its target object
	local direct = targetRegistry[instance] -- drones register their own body part, so a direct hit resolves here
	if direct then -- early out avoids an ancestor walk for the common drone case
		return direct -- the part itself is a registered target
	end
	local model = instance:FindFirstAncestorOfClass("Model") -- limbs/accessories of a character sit under the character model
	return if model then targetRegistry[model] else nil -- characters are registered by model, not by any single limb
end

--------------------------------------------------------------------------------
-- Ballistics
--------------------------------------------------------------------------------

local function solveIntercept(origin: Vector3, targetPos: Vector3, targetVel: Vector3, speed: number): Vector3? -- straight-line lead
	-- Solve |relative + targetVel*t| = speed*t for t, which expands to a*t^2 + b*t + c = 0.
	local relative = targetPos - origin -- vector from muzzle to target right now
	local a = targetVel:Dot(targetVel) - speed * speed -- negative when the bullet is faster than the target (normal case)
	local b = 2 * relative:Dot(targetVel) -- positive when target moves away, which lengthens the flight
	local c = relative:Dot(relative) -- squared distance; always positive
	local t: number -- time of flight we are solving for
	if math.abs(a) < 1e-6 then -- equal speeds degenerate the quadratic into a linear equation
		if math.abs(b) < 1e-6 then -- no relative motion either: there is no solution
			return nil -- caller falls back to aiming at the current position
		end
		t = -c / b -- linear solution of b*t + c = 0
	else
		local discriminant = b * b - 4 * a * c -- negative means the bullet can never catch the target
		if discriminant < 0 then -- unreachable target
			return nil -- caller falls back
		end
		local root = math.sqrt(discriminant) -- shared by both roots, computed once
		local t1 = (-b - root) / (2 * a) -- first candidate time
		local t2 = (-b + root) / (2 * a) -- second candidate time
		t = if t1 > 0 and t2 > 0 then math.min(t1, t2) else math.max(t1, t2) -- earliest positive time is the real intercept
	end
	if t <= 0 then -- intercept in the past is meaningless
		return nil -- caller falls back
	end
	return targetPos + targetVel * t -- where the target will be when the bullet arrives
end

local function solveBallisticDirection(origin: Vector3, aimPoint: Vector3, speed: number, gravity: number): Vector3? -- launch direction
	local delta = aimPoint - origin -- full displacement to cover
	local flat = Vector3.new(delta.X, 0, delta.Z) -- horizontal component; gravity only acts on Y
	local x = flat.Magnitude -- horizontal range
	if x < 1e-3 or gravity < 1e-3 then -- straight up/down or no gravity: arcs are irrelevant
		return if delta.Magnitude > 1e-3 then delta.Unit else nil -- avoid NaN from .Unit of a zero vector
	end
	local y = delta.Y -- height difference (positive = target above)
	local v2 = speed * speed -- reused several times below
	local inner = v2 * v2 - gravity * (gravity * x * x + 2 * y * v2) -- discriminant of the projectile-range equation
	if inner < 0 then -- target is beyond max range at this muzzle speed
		return nil -- turret holds fire rather than wasting shots
	end
	local angle = math.atan((v2 - math.sqrt(inner)) / (gravity * x)) -- minus root = low, flat arc (shorter flight, easier to hit)
	return flat.Unit * math.cos(angle) + Vector3.yAxis * math.sin(angle) -- rebuild a unit 3D vector from yaw (flat) and pitch (angle)
end

local function solveFiringSolution(origin: Vector3, targetPos: Vector3, targetVel: Vector3, speed: number, gravity: number): Vector3?
	local aimPoint = solveIntercept(origin, targetPos, targetVel, speed) or targetPos -- straight-line lead is a good first guess
	local direction: Vector3? = nil -- result of the latest pass
	for _ = 1, CONFIG.SOLVER_ITERATIONS do -- an arc flies longer than a straight line, so refine the lead with the real flight time
		direction = solveBallisticDirection(origin, aimPoint, speed, gravity) -- angle needed to hit the current aim point
		if not direction then -- aim point became unreachable
			return nil -- no valid solution this frame
		end
		local horizontalSpeed = speed * Vector3.new(direction.X, 0, direction.Z).Magnitude -- horizontal speed is constant in flight
		if horizontalSpeed < 1e-3 then -- firing straight up: horizontal time is undefined
			break -- keep the last direction
		end
		local range = Vector3.new(aimPoint.X - origin.X, 0, aimPoint.Z - origin.Z).Magnitude -- horizontal distance to aim point
		aimPoint = targetPos + targetVel * (range / horizontalSpeed) -- flight time = range / horizontal speed, re-lead with it
	end
	return direction -- converged launch direction (unit vector)
end

--------------------------------------------------------------------------------
-- Maid: tiny resource tracker (pattern popularised by Quenty's Nevermore, written from scratch here)
--------------------------------------------------------------------------------

local Maid = {} -- class table; instances look methods up here via __index
Maid.__index = Maid -- makes setmetatable(obj, Maid) forward missing keys to the class

function Maid.new(): any -- constructor
	return setmetatable({ _tasks = {} :: { MaidTask } }, Maid) -- each maid owns its own task list
end

function Maid:Give(task: MaidTask): any -- registers a resource and hands it back so creation and tracking fit on one line
	table.insert(self._tasks, task) -- order matters: cleaned in reverse (LIFO) like a stack unwind
	return task -- return value lets callers write local x = maid:Give(Instance.new(...))
end

function Maid:Clean(): () -- releases everything this maid owns
	for index = #self._tasks, 1, -1 do -- reverse order: things created last (children, callbacks) die first
		local task = self._tasks[index] -- current resource
		if typeof(task) == "RBXScriptConnection" then -- signal connection
			task:Disconnect() -- stops the callback from firing on a dead object
		elseif typeof(task) == "Instance" then -- physical/GUI object
			task:Destroy() -- also disconnects all of its own signals
		else -- remaining case is a cleanup function
			task() -- arbitrary teardown, e.g. unregistering from a table
		end
		self._tasks[index] = nil -- shrinking from the end keeps the array contiguous
	end
end

--------------------------------------------------------------------------------
-- Shared effects / projectile pool
--------------------------------------------------------------------------------

local function createNeonPart(name: string, shape: Enum.PartType, size: Vector3, color: Color3, cframe: CFrame, parent: Instance): Part
	local part = Instance.new("Part") -- un-parented while configuring so property changes don't replicate one by one
	part.Name = name -- readable in Explorer
	part.Shape = shape -- set before Size because Ball shape forces a uniform size
	part.Size = size -- final dimensions
	part.Color = color -- visual identity
	part.Material = Enum.Material.Neon -- glow reads well at range without needing lights
	part.Anchored = true -- we drive position by CFrame ourselves, physics must not interfere
	part.CanCollide = false -- purely visual/raycast-driven, should never push characters
	part.CanTouch = false -- hit detection is done via raycasts, so Touched events are wasted work
	part.CastShadow = false -- many tiny moving shadows cost GPU for no visual gain
	part.CFrame = cframe -- initial placement
	part.Parent = parent -- parent last: one replication packet with all properties set
	return part -- caller keeps the reference
end

local function spawnImpactEffect(position: Vector3, color: Color3): () -- brief expanding flash where a projectile landed
	local flash = createNeonPart("Impact", Enum.PartType.Ball, Vector3.one * 0.5, color, CFrame.new(position), projectileFolder) -- inside the excluded folder
	local info = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out) -- fast-out easing feels punchy
	TweenService:Create(flash, info, { Size = Vector3.one * 3, Transparency = 1 }):Play() -- grow and fade simultaneously
	Debris:AddItem(flash, info.Time + 0.05) -- destroy shortly after the tween ends, without a yielding thread
end

local function acquireProjectilePart(): BasePart -- pops a pooled part or creates one if the pool is empty
	local part = table.remove(projectilePool) -- removing from the end is O(1)
	if part then -- reuse path, the common case once the game is warmed up
		return part -- already configured, only needs moving
	end
	return createNeonPart("Projectile", Enum.PartType.Block, CONFIG.PROJECTILE_SIZE, CONFIG.PROJECTILE_COLOR, CONFIG.PARK_CFRAME, projectileFolder) -- cold path
end

local function releaseProjectilePart(part: BasePart): () -- returns a part to the pool instead of destroying it
	part.CFrame = CONFIG.PARK_CFRAME -- hide it far away; cheaper than toggling Parent (which re-replicates the instance)
	table.insert(projectilePool, part) -- available for the next shot
end

local function spawnProjectile(origin: Vector3, velocity: Vector3, damage: number, source: any): () -- public entry used by turrets
	local part = acquireProjectilePart() -- pooled visual
	part.CFrame = CFrame.lookAt(origin, origin + velocity) -- point the tracer along its flight direction immediately
	table.insert(activeProjectiles, { -- simulation record; position lives here, the part just mirrors it
		Part = part,
		Position = origin,
		Velocity = velocity,
		Age = 0,
		Damage = damage,
		Source = source,
	})
end

local function handleImpact(projectile: Projectile, result: RaycastResult): () -- applies damage and feedback for a hit
	local target = resolveTarget(result.Instance) -- nil when we hit scenery
	if target and target:IsAlive() then -- don't keep damaging something already dying
		local killed = target:ApplyDamage(projectile.Damage) -- polymorphic call: drone or character handles its own damage
		if killed and projectile.Source then -- credit the shooter only for the final blow
			projectile.Source:RegisterKill() -- turret updates its Kills attribute
		end
	end
	local color = if target then Color3.fromRGB(255, 80, 80) else Color3.fromRGB(255, 220, 150) -- red = hit target, pale = miss
	spawnImpactEffect(result.Position, color) -- visual confirmation of where the shot landed
end

local function stepProjectiles(dt: number): () -- integrates every projectile once per frame
	local gravity = Vector3.new(0, -workspace.Gravity, 0) -- read each frame so changing Workspace.Gravity takes effect live
	table.clear(moveParts) -- reuse buffers to avoid garbage every frame
	table.clear(moveCFrames) -- parallel buffer must stay the same length as moveParts
	for index = #activeProjectiles, 1, -1 do -- iterate backwards so swap-removal never skips an element
		local projectile = activeProjectiles[index] -- current record
		projectile.Age += dt -- lifetime bookkeeping
		local displacement = projectile.Velocity * dt + gravity * (0.5 * dt * dt) -- exact kinematics: s = v*t + 1/2*g*t^2
		local result = workspace:Raycast(projectile.Position, displacement, worldParams) -- sweep the whole segment so fast bullets can't tunnel
		if result or projectile.Age >= CONFIG.PROJECTILE_LIFETIME then -- hit something or expired
			if result then -- only real hits produce damage/effects
				handleImpact(projectile, result) -- damage + flash
			end
			releaseProjectilePart(projectile.Part) -- back to the pool
			activeProjectiles[index] = activeProjectiles[#activeProjectiles] -- swap-remove: O(1) instead of table.remove's O(n) shift
			activeProjectiles[#activeProjectiles] = nil -- drop the now-duplicated last slot
		else -- still flying
			projectile.Position += displacement -- advance simulated position
			projectile.Velocity += gravity * dt -- v = v0 + g*t
			table.insert(moveParts, projectile.Part) -- queue the visual move
			table.insert(moveCFrames, CFrame.lookAt(projectile.Position, projectile.Position + projectile.Velocity)) -- nose follows the arc
		end
	end
	if #moveParts > 0 then -- BulkMoveTo with empty arrays is wasted engine call
		workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged) -- one engine call moves every bullet
	end
end

--------------------------------------------------------------------------------
-- CharacterTarget: adapts a player character to the Targetable interface
--------------------------------------------------------------------------------

local CharacterTarget = {} -- class table
CharacterTarget.__index = CharacterTarget -- method lookup for instances

function CharacterTarget.new(character: Model, humanoid: Humanoid, root: BasePart): any -- wraps an existing character
	local self = setmetatable({}, CharacterTarget) -- instance inherits methods via __index
	self.Kind = "Player" -- turrets use this to respect their TargetPlayers attribute
	self.Character = character -- registry key
	self.Humanoid = humanoid -- health source
	self.Root = root -- position/velocity source; the physics engine already tracks its velocity
	targetRegistry[character] = self -- registered by model so any limb resolves through resolveTarget
	return self -- caller may ignore it; the registry holds the reference
end

function CharacterTarget:GetPosition(): Vector3 -- aim at the torso centre
	return self.Root.Position -- HumanoidRootPart sits at torso height
end

function CharacterTarget:GetVelocity(): Vector3 -- velocity is free: the physics engine already computed it
	return self.Root.AssemblyLinearVelocity -- includes walking, jumping and falling
end

function CharacterTarget:IsAlive(): boolean -- dead or despawned characters are not targets
	return self.Humanoid.Health > 0 and self.Root:IsDescendantOf(workspace) -- second check covers respawn/reset
end

function CharacterTarget:ApplyDamage(amount: number): boolean -- damage via Humanoid API
	self.Humanoid:TakeDamage(amount) -- TakeDamage respects ForceFields, unlike setting Health directly
	return self.Humanoid.Health <= 0 -- lethal hit flag
end

--------------------------------------------------------------------------------
-- Drone: moving practice target following a parametric figure-eight
--------------------------------------------------------------------------------

local Drone = {} -- class table
Drone.__index = Drone -- method lookup for instances

function Drone.new(spawnPart: BasePart): any -- creates a drone bound to a tagged spawn part
	local self = setmetatable({}, Drone) -- instance inherits Drone methods
	self.Kind = "Drone" -- always targetable by every turret
	self.SpawnPart = spawnPart -- centre of the flight path; moving the part in Studio moves the path
	self.Radius = readNumber(spawnPart, "Radius", 30) -- half-width of the figure-eight
	self.AngularSpeed = readNumber(spawnPart, "Speed", 0.5) -- radians of path parameter per second
	self.Phase = math.random() * 2 * math.pi -- desync drones that share settings
	self.Health = 0 -- set properly in _build
	self.Velocity = Vector3.zero -- analytic velocity, updated every step
	self.Destroyed = false -- true once the spawn tag is removed; blocks pending respawns
	self.Maid = Maid.new() -- owns everything belonging to the current body
	self:_build() -- create the first body
	return self -- stored in drones table by the tag binder
end

function Drone:_sample(now: number): (Vector3, Vector3) -- position and its exact derivative at a given time
	local w = self.AngularSpeed -- chain-rule factor: d(sin(k*w*t))/dt = k*w*cos(k*w*t)
	local t = now * w + self.Phase -- path parameter
	local r = self.Radius -- shorthand
	local offset = Vector3.new(math.sin(t) * r, math.sin(3 * t) * 3, math.sin(2 * t) * r * 0.5) -- Lissajous 1:2 = figure-eight, 3x bob on Y
	local velocity = Vector3.new(math.cos(t) * r * w, math.cos(3 * t) * 9 * w, math.cos(2 * t) * r * w) -- analytic derivative of offset
	return self.SpawnPart.Position + offset, velocity -- world position and studs/s velocity
end

function Drone:_build(): () -- creates (or recreates) the visible body and health bar
	local position = self:_sample(os.clock()) -- start on the path, not at the centre (extra return value is discarded)
	local body = self.Maid:Give(createNeonPart("Drone", Enum.PartType.Ball, Vector3.one * CONFIG.DRONE_SIZE, CONFIG.DRONE_COLOR, CFrame.new(position), droneFolder))
	local gui = self.Maid:Give(Instance.new("BillboardGui")) -- floating health bar that always faces the camera
	gui.Size = UDim2.fromScale(4, 0.4) -- BillboardGui scale is in studs, so the bar keeps its world size
	gui.StudsOffset = Vector3.new(0, CONFIG.DRONE_SIZE, 0) -- hover above the sphere
	gui.AlwaysOnTop = true -- readable through scenery
	gui.Parent = body -- follows the body automatically
	local background = Instance.new("Frame") -- dark track behind the fill
	background.Size = UDim2.fromScale(1, 1) -- fill the billboard
	background.BackgroundColor3 = Color3.fromRGB(30, 30, 30) -- neutral dark
	background.BorderSizePixel = 0 -- flat look
	background.Parent = gui -- destroyed with gui
	local fill = Instance.new("Frame") -- the part that shrinks with health
	fill.Size = UDim2.fromScale(1, 1) -- full health
	fill.BackgroundColor3 = Color3.fromRGB(90, 230, 120) -- green
	fill.BorderSizePixel = 0 -- flat look
	fill.Parent = background -- scaled relative to the track
	self.Body = body -- used by GetPosition/Step
	self.HealthFill = fill -- tweened in ApplyDamage
	self.Health = CONFIG.DRONE_MAX_HEALTH -- full health on (re)spawn
	targetRegistry[body] = self -- become visible to turrets
	self.Maid:Give(function() -- unregister when the body is cleaned
		targetRegistry[body] = nil -- prevents turrets from aiming at a destroyed part
	end)
end

function Drone:Step(now: number): () -- moves the drone along its path
	if self.Health <= 0 then -- dead drones wait for respawn and have no body
		return -- nothing to move
	end
	local position, velocity = self:_sample(now) -- evaluate the path analytically: no drift, framerate independent
	self.Velocity = velocity -- exposed through GetVelocity for turret lead
	local facing = if velocity.Magnitude > 1e-3 then position + velocity else position + Vector3.zAxis -- lookAt needs two distinct points
	self.Body.CFrame = CFrame.lookAt(position, facing) -- face the direction of travel
end

function Drone:GetPosition(): Vector3 -- Targetable
	return self.Body.Position -- centre of the sphere
end

function Drone:GetVelocity(): Vector3 -- Targetable
	return self.Velocity -- analytic velocity from _sample (anchored parts report zero AssemblyLinearVelocity)
end

function Drone:IsAlive(): boolean -- Targetable
	return self.Health > 0 and not self.Destroyed -- both conditions remove it from targeting
end

function Drone:ApplyDamage(amount: number): boolean -- Targetable
	self.Health = math.max(self.Health - amount, 0) -- never negative so the bar can't invert
	local goal = { Size = UDim2.fromScale(self.Health / CONFIG.DRONE_MAX_HEALTH, 1) } -- bar width = health ratio
	TweenService:Create(self.HealthFill, TweenInfo.new(0.15), goal):Play() -- smooth shrink instead of a jump
	if self.Health > 0 then -- survived
		return false -- not a kill
	end
	local explosion = Instance.new("Explosion") -- built-in particle burst for feedback
	explosion.Position = self.Body.Position -- at the drone
	explosion.BlastPressure = 0 -- purely visual: don't fling nearby players
	explosion.DestroyJointRadiusPercent = 0 -- don't kill characters standing near it
	explosion.Parent = workspace -- parenting triggers the effect
	self.Maid:Clean() -- removes body, gui and registry entry in one call
	task.delay(CONFIG.DRONE_RESPAWN_TIME, function() -- schedule respawn without blocking
		if not self.Destroyed then -- spawn may have been untagged during the delay
			self:_build() -- fresh body, full health
		end
	end)
	return true -- lethal hit
end

function Drone:Destroy(): () -- called when the spawn part loses its tag or is deleted
	self.Destroyed = true -- cancels any pending respawn
	self.Health = 0 -- stops Step and IsAlive immediately
	self.Maid:Clean() -- removes visuals and registry entry
end

--------------------------------------------------------------------------------
-- Turret: acquires targets, aims a two-axis gimbal, fires ballistic projectiles
--------------------------------------------------------------------------------

local Turret = {} -- class table
Turret.__index = Turret -- method lookup for instances

function Turret.new(model: Model): any? -- returns nil for malformed models instead of erroring the whole system
	local head = model:FindFirstChild("Head") -- rotating sub-model; its pivot is the gimbal joint
	local muzzle = if head then head:FindFirstChild("Muzzle", true) else nil -- recursive find: attachment lives in the barrel part
	if not (head and head:IsA("Model") and muzzle and muzzle:IsA("Attachment")) then -- validate structure up front
		warn(`[SentryDefense] {model:GetFullName()} needs a Head model with a Muzzle attachment`) -- tells the builder what to fix
		return nil -- skip this turret, others keep working
	end
	local self = setmetatable({}, Turret) -- instance inherits Turret methods
	local pivot = head:GetPivot() -- gimbal joint as authored in Studio
	self.Model = model -- attribute host and raycast-exclusion root
	self.Head = head -- moved with PivotTo each frame
	self.Muzzle = muzzle -- world position/direction source for shots
	self.Flash = muzzle:FindFirstChildOfClass("PointLight") -- optional muzzle flash
	self.JointCFrame = CFrame.new(pivot.Position) -- rotation-free joint: yaw and pitch are rebuilt from angles each frame
	self.Yaw = math.atan2(-pivot.LookVector.X, -pivot.LookVector.Z) -- recover authored heading (LookVector is -Z in Roblox)
	self.Pitch = 0 -- start level
	self.Target = nil -- current Targetable
	self.LastScan = 0 -- os.clock() of the last search
	self.LastShot = 0 -- os.clock() of the last shot, for fire-rate gating
	self.Maid = Maid.new() -- owns the attribute connection
	self:_readAttributes() -- load tuning values
	self.Maid:Give(model.AttributeChanged:Connect(function() -- live tuning: edit attributes during a playtest
		self:_readAttributes() -- reread everything; cheap and keeps the code simple
	end))
	model:SetAttribute("Kills", model:GetAttribute("Kills") or 0) -- visible scoreboard in the Properties panel
	return self -- stored by the tag binder
end

function Turret:_readAttributes(): () -- copies attributes into fields so the hot loop never calls GetAttribute
	self.Range = readNumber(self.Model, "Range", 120) -- studs
	self.FireRate = math.max(readNumber(self.Model, "FireRate", 2), 0.1) -- shots/s, clamped so 1/FireRate never divides by zero
	self.ProjectileSpeed = readNumber(self.Model, "ProjectileSpeed", 180) -- studs/s muzzle velocity
	self.Damage = readNumber(self.Model, "Damage", 25) -- per hit
	self.TargetPlayers = self.Model:GetAttribute("TargetPlayers") == true -- opt-in: drones only unless set
end

function Turret:RegisterKill(): () -- called by projectiles on lethal hits
	self.Model:SetAttribute("Kills", (self.Model:GetAttribute("Kills") or 0) + 1) -- attributes replicate, so clients could display it
end

function Turret:_hasLineOfSight(origin: Vector3, target: Targetable): boolean -- is anything solid between muzzle and target?
	local result = workspace:Raycast(origin, target:GetPosition() - origin, worldParams) -- ray ends exactly at the target centre
	return result == nil or resolveTarget(result.Instance) == target -- clear path, or the first thing hit is the target itself
end

function Turret:_acquireTarget(origin: Vector3): Targetable? -- nearest visible valid target within range
	local best: Targetable? = nil -- winner so far
	local bestDistance = self.Range -- starting at Range doubles as the range check
	for _, target in targetRegistry do -- registry is small, so a linear scan beats maintaining a spatial structure
		if target.Kind == "Player" and not self.TargetPlayers then -- respect this turret's rules of engagement
			continue -- skip players
		end
		local distance = (target:GetPosition() - origin).Magnitude -- straight-line distance
		if distance < bestDistance and target:IsAlive() and self:_hasLineOfSight(origin, target) then -- raycast last: most expensive check
			best, bestDistance = target, distance -- new closest
		end
	end
	return best -- nil when nothing qualifies
end

function Turret:_rotateTowards(yaw: number, pitch: number, dt: number): () -- rate-limited gimbal motion
	local maxStep = CONFIG.TURN_RATE * dt -- frame-rate independent turning
	self.Yaw = stepAngle(self.Yaw, yaw, maxStep) -- horizontal axis, wraps around
	self.Pitch = stepAngle(self.Pitch, math.clamp(pitch, CONFIG.MIN_PITCH, CONFIG.MAX_PITCH), maxStep) -- vertical axis within limits
	self.Head:PivotTo(self.JointCFrame * CFrame.Angles(0, self.Yaw, 0) * CFrame.Angles(self.Pitch, 0, 0)) -- yaw first, then pitch in the yawed frame
end

function Turret:_fire(direction: Vector3): () -- launches one projectile along the solved direction
	local origin = self.Muzzle.WorldPosition -- spawn at the barrel tip
	spawnProjectile(origin, direction * self.ProjectileSpeed, self.Damage, self) -- velocity = unit direction * speed
	if self.Flash then -- flash is optional decoration
		self.Flash.Enabled = true -- light up
		task.delay(0.05, function() -- turn off next frames without yielding the loop
			self.Flash.Enabled = false -- short pulse reads as a muzzle flash
		end)
	end
end

function Turret:Step(now: number, dt: number): () -- called once per Heartbeat
	local origin = self.Muzzle.WorldPosition -- all aim math is relative to the barrel tip
	if now - self.LastScan >= CONFIG.SCAN_INTERVAL then -- throttled search
		self.LastScan = now -- reset the throttle
		self.Target = self:_acquireTarget(origin) -- may switch to a closer target or drop a hidden one
	end
	local target = self.Target -- local copy for type refinement and speed
	if target and not target:IsAlive() then -- target died between scans
		target = nil -- stop aiming at a corpse
		self.Target = nil -- force re-acquire on the next scan
	end
	if not target then -- nothing to shoot
		self:_rotateTowards(self.Yaw + CONFIG.IDLE_SWEEP_RATE * dt, 0, dt) -- slow search sweep, barrel returns to level
		return -- skip firing logic
	end
	local direction = solveFiringSolution(origin, target:GetPosition(), target:GetVelocity(), self.ProjectileSpeed, workspace.Gravity) -- lead + drop
	if not direction then -- out of ballistic range
		return -- hold position and wait for the target to come closer
	end
	local desiredYaw = math.atan2(-direction.X, -direction.Z) -- inverse of CFrame.Angles(0, yaw, 0).LookVector
	local desiredPitch = math.asin(math.clamp(direction.Y, -1, 1)) -- clamp guards asin against float error just above 1
	self:_rotateTowards(desiredYaw, desiredPitch, dt) -- swing towards the solution
	local aligned = self.Muzzle.WorldCFrame.LookVector:Dot(direction) >= CONFIG.FIRE_ALIGNMENT -- barrel close enough to the solution?
	if aligned and now - self.LastShot >= 1 / self.FireRate then -- aimed and cooled down
		self.LastShot = now -- start cooldown
		self:_fire(direction) -- fire along the exact solution, the barrel is only a visual within tolerance
	end
end

function Turret:Destroy(): () -- called when the model loses its tag or is deleted
	self.Maid:Clean() -- disconnects AttributeChanged
	self.Target = nil -- release the reference
end

--------------------------------------------------------------------------------
-- Bootstrapping
--------------------------------------------------------------------------------

local function bindTag(tag: string, onAdded: (Instance) -> (), onRemoved: (Instance) -> ()): () -- one helper for both tags, no duplicated wiring
	for _, instance in CollectionService:GetTagged(tag) do -- objects already tagged in the saved place
		task.spawn(onAdded, instance) -- isolate each so one bad object can't stop the others from loading
	end
	CollectionService:GetInstanceAddedSignal(tag):Connect(onAdded) -- tagged at runtime (or streamed in)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(onRemoved) -- untagged or destroyed
end

bindTag(CONFIG.TURRET_TAG, function(instance: Instance) -- turret added
	if not instance:IsA("Model") or turrets[instance] then -- wrong class or duplicate signal
		return -- ignore
	end
	local turret = Turret.new(instance) -- nil if malformed
	if turret then -- only track valid turrets
		turrets[instance] = turret -- start updating it
		rebuildRaycastFilter() -- new body must be excluded from every ray
	end
end, function(instance: Instance) -- turret removed
	local turret = turrets[instance :: Model] -- cast is safe: non-models were never inserted
	if turret then -- may be nil if it was malformed
		turret:Destroy() -- release connections
		turrets[instance :: Model] = nil -- stop updating it
		rebuildRaycastFilter() -- drop it from the exclude list
	end
end)

bindTag(CONFIG.DRONE_SPAWN_TAG, function(instance: Instance) -- drone spawn added
	if instance:IsA("BasePart") and not drones[instance] then -- spawn must be a part to have a Position
		drones[instance] = Drone.new(instance) -- start flying
	end
end, function(instance: Instance) -- drone spawn removed
	local drone = drones[instance :: BasePart] -- cast is safe: only BaseParts were inserted
	if drone then -- may already be gone
		drone:Destroy() -- cancels respawn and removes body
		drones[instance :: BasePart] = nil -- stop updating it
	end
end)

local function onCharacterAdded(character: Model): () -- registers a fresh character as a target
	local humanoid = character:WaitForChild("Humanoid", 10) -- character parts may still be streaming in
	local root = character:WaitForChild("HumanoidRootPart", 10) -- same reason; 10s timeout avoids an infinite yield
	if humanoid and humanoid:IsA("Humanoid") and root and root:IsA("BasePart") then -- type-check before wrapping
		CharacterTarget.new(character, humanoid, root) -- adds itself to the registry
		humanoid.Died:Once(function() -- Once auto-disconnects, no leak per life
			targetRegistry[character] = nil -- turrets stop shooting the body immediately
		end)
	end
end

local function onPlayerAdded(player: Player): () -- hooks every life of a player
	player.CharacterAdded:Connect(onCharacterAdded) -- future respawns
	player.CharacterRemoving:Connect(function(character: Model) -- reset/leave without dying
		targetRegistry[character] = nil -- never keep a removed character in the registry
	end)
	if player.Character then -- character spawned before this script connected
		task.spawn(onCharacterAdded, player.Character) -- spawn because onCharacterAdded may yield
	end
end

Players.PlayerAdded:Connect(onPlayerAdded) -- players joining later
for _, player in Players:GetPlayers() do -- players already in game (e.g. Studio play solo races the script)
	onPlayerAdded(player) -- same setup path
end

RunService.Heartbeat:Connect(function(dt: number) -- single update loop for the whole system
	local now = os.clock() -- one timestamp per frame keeps every object in sync
	for _, drone in drones do -- move targets first...
		drone:Step(now) -- ...so turrets aim at this frame's positions
	end
	for _, turret in turrets do -- then aim and fire
		turret:Step(now, dt) -- may spawn projectiles
	end
	stepProjectiles(dt) -- finally integrate bullets, including ones fired this frame
end)
