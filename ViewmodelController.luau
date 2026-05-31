--[[
Viewmodel Controller v1.0.0

I'm just focusing on the visuals for now
So there isn't anything special yet, super basic stuff for application.
Currently focusing on Spring, Recoil, Sway, Bobbing, Animations.

Press '1' to equip a gun

]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Assets = ReplicatedStorage.Assets
local Remotes = ReplicatedStorage.Remotes.Viewmodel

local Constants = require(ReplicatedStorage.Constants)
local Spring = require(ReplicatedStorage.Utils.Spring)

local Viewmodel = {}
Viewmodel.__index = Viewmodel

local BOB_SPEED = 16
local BOB_AMOUNT = 1
local SWAY_AMOUNT = 0.3
local TILT_AMOUNT = 0.15
local SPRINT_BOB_MULTIPLIER = 1.8 -- Sprint isn't a thing yet.. for now...
-- Ammo will be added in the future after im done with my semester...

--// Create a new viewmodel
function Viewmodel.new()
	local self = setmetatable({}, Viewmodel)

	self.model = script.Viewmodel:Clone()
	self.model.Parent = workspace

	local player = Players.LocalPlayer
	local humanoidDesc = Players:GetHumanoidDescriptionFromUserIdAsync(player.UserId)
	self.model.Shirt.ShirtTemplate = "rbxassetid://" .. humanoidDesc.Shirt
	self.model.BodyColors.LeftArmColor3 = humanoidDesc.LeftArmColor
	self.model.BodyColors.RightArmColor3 = humanoidDesc.RightArmColor

	self.currentWeapon = nil
	self.animations = {}
	self.visible = true
	self.isSprinting = false
	self.onWeaponChanged = nil

	self.recoilSpring = Spring.new(Vector3.zero)
	self.recoilSpring.Speed = 20
	self.recoilSpring.Damping = 1

	self.swaySpring = Spring.new(Vector3.zero)
	self.swaySpring.Speed = 8
	self.swaySpring.Damping = 0.8

	self.tiltSpring = Spring.new(Vector3.zero)
	self.tiltSpring.Speed = 10
	self.tiltSpring.Damping = 0.85

	self.bobSpring = Spring.new(Vector3.zero)
	self.bobSpring.Speed = 5
	self.bobSpring.Damping = 0.5

	self._bobClock = 0
	self._lastCameraCFrame = workspace.CurrentCamera.CFrame
	self._connections = {}

	local function onRenderStepped(dt)
		local camera = workspace.CurrentCamera
		local cameraCFrame = camera.CFrame

		local cameraDelta = self._lastCameraCFrame:Inverse() * cameraCFrame
		local angularDelta = Vector3.new(cameraDelta:ToEulerAnglesXYZ())
		self._lastCameraCFrame = cameraCFrame

		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		local moveDir = humanoid and humanoid.MoveDirection or Vector3.zero
		local isMoving = moveDir.Magnitude > 0.1
		local bobMultiplier = self.isSprinting and SPRINT_BOB_MULTIPLIER or 1

		local localMove = Vector3.zero
		if isMoving then
			localMove = cameraCFrame:VectorToObjectSpace(moveDir)
		end

		-- Camera look sway
		self.swaySpring:Impulse(Vector3.new(
			-angularDelta.Y * SWAY_AMOUNT,
			angularDelta.X * SWAY_AMOUNT,
			0
			))

		-- Movement sway (left/right)
		if isMoving then
			self.swaySpring:Impulse(Vector3.new(
				localMove.X * SWAY_AMOUNT * 0.4 * dt * 60,
				-localMove.Z * SWAY_AMOUNT * 0.2 * dt * 60,
				0
				))
		end

		-- Bobbing (up/down)
		if isMoving then
			local prevClock = self._bobClock
			self._bobClock += dt * BOB_SPEED * bobMultiplier

			local prevSin = math.sin(prevClock)
			local currSin = math.sin(self._bobClock)

			if prevSin * currSin < 0 then
				local direction = currSin > 0 and 1 or -1
				self.bobSpring:Impulse(Vector3.new(
					direction * BOB_AMOUNT * bobMultiplier,
					BOB_AMOUNT * bobMultiplier * 0.6,
					0
					))
			end
		else
			self._bobClock = 0
		end

		-- Tilt
		self.tiltSpring:Impulse(Vector3.new(0, 0, localMove.X * TILT_AMOUNT * dt * 60))

		local swayPos = self.swaySpring.Position
		local bobPos = self.bobSpring.Position
		local tiltPos = self.tiltSpring.Position
		local recoilPos = self.recoilSpring.Position

		local combinedOffset = CFrame.new(
			swayPos.X + bobPos.X,
			swayPos.Y + bobPos.Y + recoilPos.Y,
			recoilPos.Z
		) * CFrame.Angles(0, 0, tiltPos.Z)

		self.model:PivotTo(cameraCFrame * combinedOffset)

		local Camera: BasePart = self.model["Camera"]
		local modelCFrame = cameraCFrame * combinedOffset
		local cameraOffset = modelCFrame:Inverse() * Camera.CFrame
		camera.CFrame = cameraCFrame * cameraOffset
	end

	self._connections.update = RunService.RenderStepped:Connect(onRenderStepped)
	
	self._connections.cameraMode = RunService.RenderStepped:Connect(function()
		local camera = workspace.CurrentCamera
		local isFirstPerson = camera.CameraType == Enum.CameraType.Custom
			and (player.Character and player.Character:FindFirstChildOfClass("Humanoid"))
			and (camera.CFrame.Position - player.Character.Head.CFrame.Position).Magnitude < 2
		self:SetVisible(isFirstPerson == true)
	end)

	self._connections.equip = Remotes.EquipWeapon.OnClientEvent:Connect(function(weaponName)
		self:SwitchWeapon(weaponName)
	end)

	self._connections.shoot = Remotes.OnShoot.OnClientEvent:Connect(function()
		self:ApplyRecoil()
		self:PlayAnimation("Shoot")
	end)

	self._connections.playAnim = Remotes.PlayAnimation.OnClientEvent:Connect(function(animationName)
		self:PlayAnimation(animationName)
	end)

	self._connections.stopAnim = Remotes.StopAnimation.OnClientEvent:Connect(function(animationName)
		self:StopAnimation(animationName)
	end)

	return self
end

--// Switch weapon
function Viewmodel:SwitchWeapon(weaponName: string)
	if self.currentWeapon == weaponName then return end
	self.currentWeapon = weaponName
	
	if self.model["Root"]:FindFirstChild("EquipMotor") then
		self.model["Root"].EquipMotor:Destroy()
	end
	
	if self.model:FindFirstChildOfClass("Model") then
		self.model:FindFirstChildOfClass("Model"):Destroy()
	end
	
	local originalWeapon = Assets.Weapons:FindFirstChild(weaponName)
	if not originalWeapon then return end
	
	local motorCFrame = originalWeapon:GetAttribute("equipC0") or CFrame.new()
	local weapon = originalWeapon:Clone()
	weapon.Parent = self.model
	
	local motor = Instance.new("Motor6D")
	motor.Name = "EquipMotor"
	motor.Part0 = self.model["Root"]
	motor.Part1 = weapon.PrimaryPart
	motor.C0 = motorCFrame
	motor.Parent = self.model["Root"]
	
	self:ResetAnimations()
end

--// Aim down sight
function Viewmodel:Aim(isAiming: boolean)
	if not self.currentWeapon then return end
	
	if isAiming then
		self:PlayAnimation("Aim")
	else
		self:StopAnimation("Aim")
	end
end

--// Apply recoil to viewmodel
function Viewmodel:ApplyRecoil()
	self.recoilSpring:Impulse(Vector3.new(0, -1, 0))
end

--// Play animation on viewmodel
function Viewmodel:PlayAnimation(animationName: string)
	local originalWeapon = Assets.Weapons:FindFirstChild(self.currentWeapon)
	if not originalWeapon then return end

	local animation = originalWeapon.Animations:FindFirstChild(animationName)
	if not animation then return end

	if not self.animations[animationName] then
		self.animations[animationName] = self.model.Humanoid.Animator:LoadAnimation(animation)
	end

	local track = self.animations[animationName]
	track:Stop()
	track:Play(0)
end

--// Stop animation on viewmodel
function Viewmodel:StopAnimation(animationName: string)
	if not self.animations[animationName] then return end
	self.animations[animationName]:Stop()
end

--// Stop all animations on viewmodel
function Viewmodel:StopAllAnimations()
	for _, animation in pairs(self.animations) do
		animation:Stop()
	end
end

--// Reset all animations on viewmodel
function Viewmodel:ResetAnimations()
	self:StopAllAnimations()
	self.animations = {}
end

--// Inspect viewmodel/current weapon
-- none of the weapon have inspect anim
function Viewmodel:Inspect()
	self:StopAllAnimations()
	self:PlayAnimation("Inspect")
end

--// Set the viewmodel visibility
function Viewmodel:SetVisible(visible: boolean)
	if self.visible == visible then return end
	self.visible = visible
	
	for _, part in pairs(self.model:GetDescendants()) do
		if part:IsA("BasePart") or part:IsA("Decal") then
			part.LocalTransparencyModifier = visible and 0 or 1
		end
	end
end

--// Destroy viewmodel
function Viewmodel:Destroy()
	
	-- Disconnect all connections
	for _, connection in pairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
	
	self:ResetAnimations()
	
	-- Destroy model
	if self.model and self.model.Parent then
		self.model:Destroy()
	end
	
	self.model = nil
	self.currentWeapon = nil
end

return Viewmodel
