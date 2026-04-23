--[[
    VerletRope.luau
    ═══════════════════════════════════════════════════════════════════════════
    A fully server-side rope and chain simulation engine built on Verlet
    Integration — a numerical integration method popular in cloth and rope
    physics since the Jakobsen (2001) GDC paper, but rarely seen implemented
    from scratch in Roblox Luau.

    ── What makes this unique ───────────────────────────────────────────────
    Most Roblox "ropes" are either RopeConstraints (black-box engine feature)
    or cosmetic bezier curves with no real physics.  This system:

        • Simulates every link as a mass-less point ("particle") in 3-D space.
        • Enforces rigid-link distance constraints via iterative relaxation —
          the same core algorithm used in AAA cloth engines.
        • Supports pinning any subset of particles to anchors (e.g. both ends,
          one end, a moving NPC hand).
        • Detects per-particle collisions with workspace geometry each frame
          using SphereCast, so ropes drape over surfaces realistically.
        • Wraps everything in a clean OOP API backed by metatables.
        • Pools the visual cylinder Parts so firing/destroying ropes is cheap.
        • Exposes a Wind vector so ropes sway in a simulated breeze.
        • Ropes can be "cut" at any link index, splitting into two independent
          simulations — a feature with zero equivalent in RopeConstraint.

    ── Physics primer (Verlet Integration) ─────────────────────────────────
    Standard Euler:   pos += vel * dt
    Verlet:           newPos = pos + (pos - prevPos) + accel * dt²

    The trick: velocity is implicit — it emerges from (pos - prevPos).
    This means:
        • No explicit velocity storage per particle (saves memory).
        • Constraints can teleport particles without corrupting velocity in
          a way that causes explosions (Euler's worst failure mode).
        • Energy is near-perfectly conserved over many frames.

    After integrating, we run SOLVER_ITERATIONS passes of constraint
    relaxation.  Each pass pushes every pair of adjacent particles back to
    their rest length.  More iterations = stiffer rope, fewer = rubbery.

	** You guys asked for detailed comments btw, feels like submitting an assignment ngl
--]]

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. SERVICES & CONSTANTS
-- ═══════════════════════════════════════════════════════════════════════════

local RunService = game:GetService("RunService")
local Debris     = game:GetService("Debris")

-- Gravity vector pulled from workspace so it respects place-level overrides.
local GRAVITY = Vector3.new(0, -workspace.Gravity, 0)

-- Number of constraint-relaxation passes per physics step.
-- 6 gives a stiff, believable rope without heavy CPU cost.
local SOLVER_ITERATIONS = 6

-- Radius used for per-particle SphereCast collision queries (studs).
-- Matches the visual cylinder radius so the rope "sits" on surfaces.
local PARTICLE_RADIUS = 0.07

-- Damping factor applied to implicit velocity each frame (0-1).
-- 0.985 ≈ slight energy loss, prevents endless oscillation.
local DAMPING = 0.985

-- dt cap — prevents the solver from exploding during a lag spike.
local MAX_DT = 1 / 30

-- Wind acceleration added to every free (non-pinned) particle each frame.
-- Exposed on RopeManager so a game script can animate it over time.
local WindAcceleration = Vector3.new(0, 0, 0)

-- Visual cylinder dimensions.  Radius matches PARTICLE_RADIUS.
local SEGMENT_RADIUS = PARTICLE_RADIUS
-- Height is overridden each frame to match actual inter-particle distance.
local SEGMENT_BASE_HEIGHT = 0.5

-- Maximum simultaneous ropes before the oldest is auto-removed.
local MAX_ROPES = 40

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. PART POOL  —  recycle cylinder Parts to avoid per-frame Instance.new
-- ═══════════════════════════════════════════════════════════════════════════

local PartPool = {}
PartPool.__index = PartPool

--[[
    PartPool.new(template, size)
    ────────────────────────────
    Pre-creates `size` clones of `template` and parks them off-world.
    Template should be an anchored, non-colliding cylinder Part.
--]]
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

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. PARTICLE  —  a single verlet point-mass
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    A Particle stores:
        pos      — current world position
        prevPos  — position last frame  (velocity = pos - prevPos implicitly)
        pinned   — if true, this particle is immovable (anchored to a CFrame)
        anchor   — optional function() → CFrame  called each frame when pinned
                   (lets a pin track a moving Part, e.g. a swinging NPC hand)
--]]
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

--[[
    Particle:Integrate(dt)
    ───────────────────────
    Advances the particle using the Verlet formula:
        newPos = pos + (pos - prevPos)*DAMPING + accel * dt²

    Pinned particles skip integration and are instead moved to their anchor.
    This is the key insight: constraints can forcibly set positions without
    blowing up the simulation, because velocity is derived, not stored.
--]]
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

	-- ── Collision response ───────────────────────────────────────────────
	-- SphereCast from prevPos toward newPos catches geometry between frames.
	local rayDir = newPos - self.pos
	local rayLen = rayDir.Magnitude
	if rayLen > 0.001 then
		local hit = workspace:Spherecast(self.pos, PARTICLE_RADIUS, rayDir)
		if hit then
			-- Project the particle onto the hit surface, offset by radius.
			-- Reflect the implicit velocity across the surface normal for a
			-- small bounce (coefficient 0.15 — almost fully inelastic).
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

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. ROPE  —  a chain of Particles connected by length constraints
-- ═══════════════════════════════════════════════════════════════════════════

local Rope = {}
Rope.__index = Rope

--[[
    Rope.new(config)
    ────────────────
    config fields:
        startPos   Vector3         — world position of first particle
        endPos     Vector3         — world position of last particle
        segments   number          — link count (more = more detailed sag)
        startAnchor function?      — optional () → CFrame  for the start pin
        endAnchor   function?      — optional () → CFrame  for the end pin
        color      Color3?         — visual colour override
        sag        number?         — slack factor (1 = taut, >1 = saggy)

    The rest length of each segment is:
        (startPos - endPos).Magnitude * sag / segments
    so sag > 1 adds extra rope length, letting gravity pull it into a catenary.
--]]
function Rope.new(config)
	local self = setmetatable({}, Rope)

	local N       = config.segments or 20
	local start   = config.startPos
	local finish  = config.endPos
	local sag     = config.sag or 1.2     -- 20% extra length by default

	-- ── Build particle chain ─────────────────────────────────────────────
	-- Particles are spaced linearly from start to finish at construction.
	-- Gravity will immediately begin pulling the chain into a catenary shape.
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

	-- ── Acquire visual segments from pool ────────────────────────────────
	-- We need N cylinders for N inter-particle gaps.
	self._visuals = {}
	for i = 1, N do
		local part = SegmentPool:Acquire()
		part.Color = config.color or Color3.fromRGB(180, 140, 90)
		self._visuals[i] = part
	end

	return self
end

--[[
    Rope:_solveConstraints()
    ─────────────────────────
    The heart of Verlet rope physics.

    For each adjacent pair (A, B):
        1. Measure the current distance |AB|.
        2. Compute the error:  delta = current - restLength.
        3. Push A and B apart (or together) by delta/2 each along AB.

    Pinned particles absorb none of the correction — only free ones move.
    Iterating this SOLVER_ITERATIONS times converges the chain toward a
    physically plausible shape without needing to solve a linear system.
--]]
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
			-- Pinned particles absorb nothing — the rope stretches away from
			-- the anchor rather than moving it.
			if not a.pinned then a.pos += correction end
			if not b.pinned then b.pos -= correction end
		end
	end
end

--[[
    Rope:_updateVisuals()
    ──────────────────────
    Positions each cylinder segment between its two bounding particles.

    A cylinder's default orientation has its length along the X axis.
    CFrame.lookAt points +Z toward target, so we compose a rotation that
    aligns the cylinder's long axis with the inter-particle vector.

    The cylinder is scaled on its X axis to match the live inter-particle
    distance, so the rope "stretches" slightly instead of showing gaps.
--]]
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

--[[
    Rope:Step(dt)
    ──────────────
    Full simulation step for this rope:
        1. Integrate every particle (verlet + collision).
        2. Solve distance constraints SOLVER_ITERATIONS times.
        3. Refresh cylinder CFrames/sizes to match new particle positions.
--]]
function Rope:Step(dt: number)
	if not self._alive then return end

	for _, p in ipairs(self._particles) do
		p:Integrate(dt)
	end

	self:_solveConstraints()
	self:_updateVisuals()
end

--[[
    Rope:Pin(index, anchorFn)
    ──────────────────────────
    Dynamically pin or re-pin a particle at `index` (1 = start, #pts = end).
    `anchorFn` is an optional function() → CFrame; passing nil pins in place.
    Passing pinned = false un-pins (releases) the particle.
--]]
function Rope:Pin(index: number, anchorFn, pinned: boolean)
	local p = self._particles[index]
	if not p then return end
	p.pinned = (pinned == nil) and true or pinned
	p.anchor = anchorFn
end

--[[
    Rope:Cut(index) → Rope, Rope
    ─────────────────────────────
    Splits the rope at link `index`, returning two new independent Rope objects.

    Implementation:
        • The left half keeps particles [1 .. index], inheriting the original
          start pin.  Its last particle becomes free.
        • The right half keeps particles [index+1 .. N+1], inheriting the
          original end pin.  Its first particle becomes free.
        • Visuals and particles are redistributed; the original rope is
          destroyed.

    This is mechanically impossible with RopeConstraint — a genuine capability
    unique to a custom simulation.
--]]
function Rope:Cut(index: number)
	if not self._alive then return nil, nil end
	if index < 1 or index >= #self._particles then return nil, nil end

	-- ── Build LEFT rope ─────────────────────────────────────────────────
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

	-- ── Build RIGHT rope ─────────────────────────────────────────────────
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

--[[
    Rope:Destroy()
    ───────────────
    Cleanly removes the rope: releases all visual parts back to the pool
    and marks the rope dead so the manager stops stepping it.
--]]
function Rope:Destroy()
	if not self._alive then return end
	self._alive = false

	for _, part in ipairs(self._visuals) do
		SegmentPool:Release(part)
	end
	self._visuals   = {}
	self._particles = {}
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. ROPE MANAGER  —  global registry and Heartbeat driver
-- ═══════════════════════════════════════════════════════════════════════════

--[[
    RopeManager holds all live Rope objects and drives the simulation from a
    single RunService.Heartbeat connection.  One connection for N ropes is far
    cheaper than N individual connections (each connection has overhead).
--]]
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

-- ═══════════════════════════════════════════════════════════════════════════
-- 6. PUBLIC API
-- ═══════════════════════════════════════════════════════════════════════════

local VerletRope = {}

--[[
    VerletRope.Create(config) → Rope
    ─────────────────────────────────
    The primary entry point.  Creates a rope and registers it with the manager.

    config:  see Rope.new() documentation above.
    Returns: the Rope instance (hold onto it to Pin, Cut, or Destroy later).
--]]
function VerletRope.Create(config): typeof(Rope)
	local rope = Rope.new(config)
	RopeManager:Add(rope)
	return rope
end

-- Expose the manager so game scripts can set Wind or query Count.
VerletRope.Manager = RopeManager

-- ═══════════════════════════════════════════════════════════════════════════
-- DEMO  —  three ropes with different configs to prove all features work
-- ═══════════════════════════════════════════════════════════════════════════
--[[
    This demo block creates three ropes the moment the script runs:

        Rope A  — a standard catenary between two fixed anchors, 20 segments.
        Rope B  — a long loose rope pinned only at the top, 28 segments,
                  to demonstrate free-hanging physics.
        Rope C  — a rope that gets cut at link 10 after 4 seconds, showing
                  the unique cut mechanic.

    Wind slowly oscillates so the ropes sway.

    Remove or guard with an `if IS_DEMO then` flag before shipping.
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
	
	-- ── Rope A: catenary between two fixed pillars ───────────────────────────
	local ropeA = VerletRope.Create({
		startPos    = Vector3.new(-10, 20, 0),
		endPos      = Vector3.new( 10, 20, 0),
		segments    = 20,
		sag         = 1.35,
		color       = Color3.fromRGB(180, 130, 80),
	})

	-- ── Rope B: long free-hanging rope (only top pinned) ────────────────────
	local ropeB = VerletRope.Create({
		startPos = Vector3.new(0, 30, 5),
		endPos   = Vector3.new(0,  8, 5),
		segments = 28,
		sag      = 1.5,
		color    = Color3.fromRGB(120, 100, 70),
	})
	-- Un-pin the bottom end so it swings freely.
	ropeB:Pin(29, nil, false)

	-- ── Rope C: rope that gets cut mid-simulation after 4 seconds ───────────
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

-- ─────────────────────────────────────────────────────────────────────────
return VerletRope
