--[[
VertelRope.luau:
A fully server-side rope and chain simulation engine built on Verlet Integration.
Rewritten comments manually 🥀
--]]

-- =================================================================
-- VARIABLES
-- =================================================================

local RunService = game:GetService("RunService")
local Debris     = game:GetService("Debris")

-- Gravity Vector3
local GRAVITY = Vector3.new(0, -workspace.Gravity, 0)

-- # of constraint-relaxation passes per physics step.
local SOLVER_ITERATIONS = 6

-- Radius used for per-particle SphereCast collision queries in studs.
local PARTICLE_RADIUS = 0.07

-- Damping factor applied to implicit velocity each frame (0-1).
local DAMPING = 0.985

local MAX_DT = 1 / 30

-- Wind acceleration added to each frame.
local WindAcceleration = Vector3.new(0, 0, 0)

local SEGMENT_RADIUS = PARTICLE_RADIUS
local SEGMENT_BASE_HEIGHT = 0.5

-- Max ropes amount, if exceeds then the oldest rope get removed.
local MAX_ROPES = 40

-- =================================================================
-- Part Pool: recycle cylinder Parts to avoid per-frame Instance.new
-- =================================================================

local PartPool = {}
PartPool.__index = PartPool

function PartPool.new(template: BasePart, size: number)
	local self   = setmetatable({}, PartPool)
	self._free   = {}      -- idle parts ready for reuse
	self._tmpl   = template

	-- Pre-warm: cloning now avoids allocations during gameplay.
	for _ = 1, size do
		local p = template:Clone()
		p.Transparency = 1
		p.CFrame = CFrame.new(0, -2000, 0)
		p.Parent = workspace.Ropes
		table.insert(self._free, p)
	end
	return self
end

-- Acquire: grab an idle Part, or clone a fresh one if the pool ran dry.
function PartPool:Acquire(): BasePart
	local part = table.remove(self._free)
	if not part then
		part = self._tmpl:Clone()
		part.Anchored   = true
		part.CanCollide = false
		part.Parent     = workspace.Ropes
	end
	part.Transparency = 0
	return part
end

-- Release: hide and re-queue a Part for reuse.
function PartPool:Release(part: BasePart)
	part.Transparency = 1
	part.CFrame = CFrame.new(0, -2000, 0)
	table.insert(self._free, part)
end

-- Build the shared segment template.  It is a thin white cylinder.
local segTemplate       = Instance.new("Part")
segTemplate.Name        = "RopeSegment"
segTemplate.Shape       = Enum.PartType.Cylinder
segTemplate.Size        = Vector3.new(SEGMENT_BASE_HEIGHT, SEGMENT_RADIUS * 2, SEGMENT_RADIUS * 2)
segTemplate.Material    = Enum.Material.SmoothPlastic
segTemplate.Color       = Color3.fromRGB(180, 140, 90)   -- rope-tan default
segTemplate.Anchored    = true
segTemplate.CanCollide  = false
segTemplate.CastShadow  = false
segTemplate.Transparency = 1
-- Not parented; PartPool clones it.

-- 96 pre-warmed segments supports about 3–4 simultaneous 25-link ropes.
local SegmentPool = PartPool.new(segTemplate, 96)

-- =================================================================
-- Particle: a single verlet point-mass
-- =================================================================

local Particle = {}
Particle.__index = Particle

function Particle.new(position: Vector3, pinned: boolean, anchorFn)
	return setmetatable({
		pos     = position,
		prevPos = position,   -- starts at rest; implicit velocity = 0
		pinned  = pinned,
		anchor  = anchorFn,   -- nil for free particles
	}, Particle)
end

function Particle:Integrate(dt: number)
	if self.pinned then
		-- If the pin has a dynamic anchor (e.g. a moving attachment),
		-- update both pos and prevPos so the implicit velocity stays zero.
		if self.anchor then
			local cf = self.anchor()
			self.prevPos = self.pos
			self.pos     = cf.Position
		end
		return
	end

	-- Verlet integration: new = current + velocity_implicit + acceleration * dt²
	local vel    = (self.pos - self.prevPos) * DAMPING
	local accel  = (GRAVITY + WindAcceleration) * dt * dt
	local newPos = self.pos + vel + accel

	-- Collision Response
	local rayDir = newPos - self.pos
	local rayLen = rayDir.Magnitude
	if rayLen > 0.001 then
		local hit = workspace:Spherecast(self.pos, PARTICLE_RADIUS, rayDir)
		if hit then
			-- Project the particle onto the hit surface, offset by radius.
			local normal     = hit.Normal
			local reflection = vel - normal * (2 * vel:Dot(normal)) * 0.15
			local safePos    = hit.Position + normal * PARTICLE_RADIUS
			self.prevPos     = safePos - reflection
			self.pos         = safePos
			return
		end
	end

	self.prevPos = self.pos
	self.pos     = newPos
end

-- =================================================================
-- ROPE - a chain of Particles connected by length constraints
-- =================================================================

local Rope = {}
Rope.__index = Rope

function Rope.new(config)
	local self = setmetatable({}, Rope)

	local N       = config.segments or 20
	local start   = config.startPos
	local finish  = config.endPos
	local sag     = config.sag or 1.2     -- 20% extra length by default

	-- Build particle chain
	self._particles = {}
	for i = 0, N do
		local t    = i / N
		local pos  = start:Lerp(finish, t)

		-- Pin the first particle to the start anchor.
		local pinned   = (i == 0 or i == N)
		local anchorFn = nil

		if i == 0 and config.startAnchor then
			anchorFn = config.startAnchor
		elseif i == N and config.endAnchor then
			anchorFn = config.endAnchor
		end

		self._particles[i + 1] = Particle.new(pos, pinned, anchorFn)
	end

	-- Rest length: straight-line span * sag factor, divided by segment count.
	-- Stored per-rope so cut segments can inherit the same rest length.
	self._restLength = (finish - start).Magnitude * sag / N
	self._segCount   = N
	self._alive      = true
	self._id         = tostring(self):sub(8)   -- unique handle for debugging

	-- Acquire visual segment from pool.
	-- We need N cylinders for N inter-particle gaps.
	self._visuals = {}
	for i = 1, N do
		local part = SegmentPool:Acquire()
		part.Color = config.color or Color3.fromRGB(180, 140, 90)
		self._visuals[i] = part
	end

	return self
end

function Rope:_solveConstraints()
	local pts = self._particles
	local rest = self._restLength

	for _ = 1, SOLVER_ITERATIONS do
		for i = 1, #pts - 1 do
			local a  = pts[i]
			local b  = pts[i + 1]
			local ab = b.pos - a.pos
			local dist = ab.Magnitude

			-- Avoid division by zero when two particles occupy the same point.
			if dist < 0.0001 then continue end

			local error = (dist - rest) / dist * 0.5
			local correction = ab * error

			-- Free particles absorb half the correction each.
			if not a.pinned then a.pos += correction end
			if not b.pinned then b.pos -= correction end
		end
	end
end

function Rope:_updateVisuals()
	local pts = self._particles

	for i = 1, #self._visuals do
		local a = pts[i]
		local b = pts[i + 1]
		if not (a and b) then continue end

		local mid  = (a.pos + b.pos) * 0.5
		local diff = b.pos - a.pos
		local len  = diff.Magnitude

		if len < 0.001 then
			self._visuals[i].Transparency = 1
			continue
		end

		self._visuals[i].Transparency = 0

		-- Build CFrame: position at midpoint, align +X along segment direction.
		-- CFrame.fromMatrix(pos, rightVec, upVec) gives us direct axis control.
		local xAxis = diff.Unit
		-- Choose an arbitrary up vector; if xAxis ≈ world up, use world right.
		local worldUp = Vector3.new(0, 1, 0)
		local ref     = math.abs(xAxis:Dot(worldUp)) > 0.99
			and Vector3.new(1, 0, 0)
			or worldUp
		local zAxis   = xAxis:Cross(ref).Unit
		local yAxis   = zAxis:Cross(xAxis).Unit

		self._visuals[i].CFrame = CFrame.fromMatrix(mid, xAxis, yAxis, zAxis)

		-- Scale the cylinder length to match the live segment distance.
		local v = self._visuals[i]
		v.Size = Vector3.new(len, SEGMENT_RADIUS * 2, SEGMENT_RADIUS * 2)
	end
end

function Rope:Step(dt: number)
	if not self._alive then return end

	for _, p in ipairs(self._particles) do
		p:Integrate(dt)
	end

	self:_solveConstraints()
	self:_updateVisuals()
end

function Rope:Pin(index: number, anchorFn, pinned: boolean)
	local p = self._particles[index]
	if not p then return end
	p.pinned = (pinned == nil) and true or pinned
	p.anchor = anchorFn
end

function Rope:Cut(index: number)
	if not self._alive then return nil, nil end
	if index < 1 or index >= #self._particles then return nil, nil end

	local leftRope       = setmetatable({}, Rope)
	leftRope._particles  = {}
	leftRope._visuals    = {}
	leftRope._restLength = self._restLength
	leftRope._alive      = true
	leftRope._id         = self._id .. "_L"

	for i = 1, index do
		leftRope._particles[i] = self._particles[i]
	end
	-- The cut end is now free.
	leftRope._particles[index].pinned = false
	leftRope._particles[index].anchor = nil

	for i = 1, index - 1 do
		leftRope._visuals[i] = self._visuals[i]
	end
	leftRope._segCount = index - 1

	local rightRope       = setmetatable({}, Rope)
	rightRope._particles  = {}
	rightRope._visuals    = {}
	rightRope._restLength = self._restLength
	rightRope._alive      = true
	rightRope._id         = self._id .. "_R"

	local offset = index
	for i = index + 1, #self._particles do
		rightRope._particles[i - offset] = self._particles[i]
	end
	-- The cut start is now free.
	rightRope._particles[1].pinned = false
	rightRope._particles[1].anchor = nil

	for i = index, #self._visuals do
		rightRope._visuals[i - index + 1] = self._visuals[i]
	end
	rightRope._segCount = #self._visuals - index

	-- Invalidate original so GC cleans it up without returning visuals.
	self._alive     = false
	self._particles = {}
	self._visuals   = {}   -- visuals transferred; don't release them

	return leftRope, rightRope
end

function Rope:Destroy()
	if not self._alive then return end
	self._alive = false

	for _, part in ipairs(self._visuals) do
		SegmentPool:Release(part)
	end
	self._visuals   = {}
	self._particles = {}
end

-- =================================================================
-- ROPE MANGER: Global registry and Heartbeat driver
-- =================================================================

local RopeManager = {}
RopeManager._ropes = {}   -- list of active Rope instances

-- Expose wind so game scripts can animate it:  RopeManager.Wind = Vector3.new(...)
RopeManager.Wind = WindAcceleration

-- Register a Rope with the manager so it gets stepped each frame.
function RopeManager:Add(rope: typeof(Rope))
	-- Enforce the cap: destroy the oldest rope if needed.
	if #self._ropes >= MAX_ROPES then
		self._ropes[1]:Destroy()
		table.remove(self._ropes, 1)
	end
	table.insert(self._ropes, rope)
end

-- Remove a specific rope by reference.
function RopeManager:Remove(rope)
	for i, r in ipairs(self._ropes) do
		if r == rope then
			r:Destroy()
			table.remove(self._ropes, i)
			return
		end
	end
end

-- Returns how many ropes are currently simulating.
function RopeManager:Count(): number
	return #self._ropes
end

-- The single Heartbeat connection that steps every live rope.
RunService.Heartbeat:Connect(function(dt: number)
	-- Update global wind from the manager's public property each frame.
	WindAcceleration = RopeManager.Wind

	local safeDt = math.min(dt, MAX_DT)

	-- Iterate backwards so we can safely remove dead ropes mid-loop.
	for i = #RopeManager._ropes, 1, -1 do
		local r = RopeManager._ropes[i]
		if r._alive then
			r:Step(safeDt)
		else
			table.remove(RopeManager._ropes, i)
		end
	end
end)

-- =================================================================
-- PUBLIC API
-- =================================================================

local VerletRope = {}

function VerletRope.Create(config): typeof(Rope)
	local rope = Rope.new(config)
	RopeManager:Add(rope)
	return rope
end

-- Expose the manager so game scripts can set Wind or query Count.
VerletRope.Manager = RopeManager

-- =================================================================
-- DEMO: three ropes with different configs to prove all features work
-- =================================================================
--[[
    Rope A: a standard catenary between two fixed anchors, 20 segments.
    Rope B: a long loose rope pinned only at the top, 28 segments, to demonstrate free-hanging physics.
    Rope C: a rope that gets cut at link 10 after 4 seconds, showing the unique cut mechanic.
--]]

-- Animate wind with a sine wave so ropes sway naturally over time.
task.spawn(function()
	while true do
		local t = os.clock()
		VerletRope.Manager.Wind = Vector3.new(
			math.sin(t * 0.4) * 12,   -- oscillate on X
			0,
			math.cos(t * 0.3) * 6     -- slight Z component
		)
		task.wait(0.05)
	end
end)

local lastTouched = 0

-- Touch the red button infront of the spawn location to spawn in the rope
workspace.Part.Touched:Connect(function()

  -- Avoid spam
	if os.clock() - lastTouched < 0.5 then return end
	lastTouched = os.clock()
	
	local ropeA = VerletRope.Create({
		startPos    = Vector3.new(-10, 20, 0),
		endPos      = Vector3.new( 10, 20, 0),
		segments    = 20,
		sag         = 1.35,
		color       = Color3.fromRGB(180, 130, 80),
	})

	local ropeB = VerletRope.Create({
		startPos = Vector3.new(0, 30, 5),
		endPos   = Vector3.new(0,  8, 5),
		segments = 28,
		sag      = 1.5,
		color    = Color3.fromRGB(120, 100, 70),
	})
	-- Un-pin the bottom end so it swings freely.
	ropeB:Pin(29, nil, false)

	local ropeC = VerletRope.Create({
		startPos = Vector3.new(-5, 25, -8),
		endPos   = Vector3.new( 5, 25, -8),
		segments = 24,
		sag      = 1.2,
		color    = Color3.fromRGB(200, 80, 60),
	})

	-- After 4 seconds, cut rope C at its midpoint.  The two halves become
	-- independent simulations that fall under gravity.
	task.delay(4, function()
		if not ropeC._alive then return end
		local leftHalf, rightHalf = ropeC:Cut(12)

		if leftHalf  then RopeManager:Add(leftHalf)  end
		if rightHalf then RopeManager:Add(rightHalf) end
	end)
end)

return VerletRope
