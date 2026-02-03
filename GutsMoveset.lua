local HitboxModule = require(game:GetService("ServerScriptService").ServerModules.Hitbox)
local Knockback = require(game:GetService("ServerScriptService").ServerModules.Knockback)

local GutsFolder = game:GetService("ReplicatedStorage").Assets.VFX.Guts
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local Remotes = game.ReplicatedStorage.Remotes

local module = {}

module.Ability1 = function(Football, Client)
	local Connection
	local Disconnect : boolean
	local Character = Client:IsA("Player") and Client.Character or Client

	if not workspace:HasTag("MatchStarted") then return end
	if _G.CheckState(Character) then return end
	if _G.GetTeam(Character) == "None" then return end
	if _G.Cooldown:Check(Character, "FirstSkill") then return end
	if _G.IsInAir(Character) then _G.Notify(Client, "Can't use while in air") return end

	local IsHeld = _G.HasBall(Character)

	if IsHeld then
		if game.Players:GetPlayerFromCharacter(Character):GetAttribute("Skill") == "Guts" then
			_G.Cooldown:Add(Character, "FirstSkill", 25)
			_G.VFX("General", "Glow", Character, Color3.fromRGB(113, 0, 0))

			local VFX = game.ReplicatedStorage.Assets.VFX.Guts.willroar:Clone()
			VFX:PivotTo(Character.Head.CFrame)
			VFX.Parent = workspace.VFX
			VFX:AddTag("GutsDash"..Character.Name)

			local Weld = Instance.new("Motor6D")
			Weld.Part0 = Character.Head
			Weld.Part1 = VFX
			Weld.Parent = VFX

			local spawnAnim = _G.AnimLoad(Character.Humanoid, "rbxassetid://71477388805403")
			spawnAnim.Priority = Enum.AnimationPriority.Action3
			spawnAnim.Looped = false
			_G.AnimPlay(Character.Humanoid, spawnAnim, .1)
			_G.AddState(Character, "WalkspeedLock", 1.6, 2)
			_G.AddState(Character, "Busy", 1.6)

			_G.SoundPlay(Character.HumanoidRootPart, "rbxassetid://74050154664369", game.SoundService.Master.SFX)

			game.Debris:AddItem(VFX, 1.6 + 0.2)
			game.Debris:AddItem(Weld, 1.6 + 0.2)

			_G.AddState(Character, "Immune", spawnAnim.Length + 0.2)

			task.wait(.75)

			_G.VFX("Guts", "CustomDash", Character)
			_G.VFX("Guts", "ScreamUser", Character)

			task.spawn(function()
				local StateFolder = Character:FindFirstChild("States")
				if StateFolder then
					for _, state in pairs(StateFolder:GetChildren()) do
						if state.Name == "SpeedBoost" and state.Value < 0 then
							state:Destroy()
						end
					end
				end
			end)

			local Hitbox = HitboxModule.Create(Client, "GutsScream", Vector3.one * 48, CFrame.new(Vector3.zero))
			local HitTarget = {}
			Hitbox:SetOnHit(function(Target)
				if _G.GetTeam(Character) == _G.GetTeam(Target) then return end
				if table.find(HitTarget, Target) then return end
				table.insert(HitTarget, Target)

				if _G.HasBall(Target) then
					Football:Drop(Target)
				end
				_G.VFX("Guts", "ScreamVictim", Target)
				_G.AddState(Target, "WalkspeedLock", 1.6, 4)
				_G.AddState(Target, "Busy", 1.6)
			end)
			Hitbox:SetDebounceTime(.1)
			Hitbox:Start()
			game.Debris:AddItem(Hitbox:GetInstance(), 1.2)
			return
		end
	else
		_G.Cooldown:Add(Character, "FirstSkill", 35)
		_G.AddState(Character, "Busy", 2)
		Character:AddTag("GutsCharge")

		local Animation =  _G.AnimLoad(Character.Humanoid, "rbxassetid://108815493298077")
		Animation.Priority = Enum.AnimationPriority.Action3
		Animation.Looped = false
		Animation:Play()

		_G.SoundPlay(Character.HumanoidRootPart, "rbxassetid://107590893553682", game.SoundService.Master.SFX)
		_G.SoundPlay(Character.HumanoidRootPart, "rbxassetid://95956803440915", game.SoundService.Master.Voicelines)


		--local Weld = Instance.new("Motor6D")
		--Weld.Part0 = Character.HumanoidRootPart
		--Weld.Part1 =  StepVFX.PrimaryPart
		--Weld.C1 = CFrame.new(Vector3.new(0, -2.4, 0))
		--Weld.Parent = StepVFX

		local Start = tick()
		local ChargeEnded = false
		local Hitbox

		Character.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Running, false)
		Character.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		
		--Character.Humanoid.PlatformStand = true

		local function HitFunction(Target : Model)
			if _G.GetTeam(Target) == _G.GetTeam(Character) then return end
			if ChargeEnded then return end

			if Target:HasTag("Counter") then
				Disconnect = true
				ChargeEnded = true
				Character:RemoveTag("GutsCharge")
				Target:SetAttribute("Countered", Character.Name)
				Character.Humanoid:AddTag("GotCountered")
				task.wait(1)
				Target:SetAttribute("Countered", nil)
				return
			end

			if not Disconnect then
				Disconnect = true
				ChargeEnded = true
				Character:RemoveTag("GutsCharge")
				--BV:Destroy()
				Animation:Stop()
				
				_G.AddState(Target, "JumpLock", 1.5)
				_G.AddState(Target, "WalkspeedLock", 1.5, 0)
				_G.AddState(Target, "Busy", 1.5, 0)

				_G.AddState(Character, "JumpLock", 1.5)
				_G.AddState(Character, "WalkspeedLock", 1.5, 0)
				_G.AddState(Character, "Busy", 1.5, 0)


				local defRoot = Target.HumanoidRootPart
				local attRoot = Character.HumanoidRootPart

				local defenderLook = defRoot.CFrame.LookVector
				local defenderRight = defRoot.CFrame.RightVector

				local direction = (attRoot.Position - defRoot.Position).Unit

				local forwardDot = defenderLook:Dot(direction)
				local rightDot = defenderRight:Dot(direction)

				local result

				if forwardDot > 0.5 then
					result = "Front"
				elseif forwardDot < -0.5 then
					result = "Back"
				else
					if rightDot > 0 then
						result = "Right"
					else
						result = "Left"
					end
				end
				

				local GrabWeld = Instance.new("Motor6D")
				GrabWeld.Parent = Character.HumanoidRootPart
				GrabWeld.C0 = CFrame.new(Vector3.new(0, 0, -2.566))
				GrabWeld.C1 = CFrame.Angles(0, math.rad(180), 0)
				GrabWeld.Name = "GrabWeld"
				GrabWeld.Part0 = Character.HumanoidRootPart
				GrabWeld.Part1 = Target.HumanoidRootPart

				if result == "Front" or result == "Left" then
					local Animation =  _G.AnimLoad(Character.Humanoid, "rbxassetid://130223853399441")
					Animation.Priority = Enum.AnimationPriority.Action3
					Animation.Looped = false
					Animation:Play()

					local anim =  _G.AnimLoad(Target.Humanoid, "rbxassetid://76871218636420")
					anim.Priority = Enum.AnimationPriority.Action3
					anim.Looped = false
					anim:Play()
					
					_G.SoundPlay(workspace.CutsceneSFX, "rbxassetid://128213799707081", game.SoundService.Master.Special)
					
					_G.VFX("Guts", "Varient1", Character)

					task.delay(1.333, function()
						GrabWeld:Destroy()
						_G.Ragdoll.Start(Target, 2)
						_G.AddState(Target, "JumpLock", 2)
						_G.AddState(Target, "WalkspeedLock", 2, 0)
						_G.AddState(Target, "Busy", 2, 0)
						if _G.HasBall(Target) then
							_G.AddState(Target, "NoPickup", 2)
							Football:Drop(Target)
							Football:Pickup(Character)
						end
						Knockback:Apply(Target, Character.HumanoidRootPart.CFrame.lookVector + Vector3.new(0, -1/6, 0) + -Character.HumanoidRootPart.CFrame.LookVector/6, 600, 1.3, true)
					end)
				end

				if result == "Back" or result == "Right" then
					local Animation =  _G.AnimLoad(Character.Humanoid, "rbxassetid://117558445170062")
					Animation.Priority = Enum.AnimationPriority.Action3
					Animation.Looped = false
					Animation:Play()

					local anim =  _G.AnimLoad(Target.Humanoid, "rbxassetid://111469229277882")
					anim.Priority = Enum.AnimationPriority.Action3
					anim.Looped = false
					anim:Play()
					
					_G.SoundPlay(workspace.CutsceneSFX, "rbxassetid://70868206787195", game.SoundService.Master.Special)
					
					_G.VFX("Guts", "Varient2", Character)

					task.delay(1.333, function()
						GrabWeld:Destroy()
						_G.Ragdoll.Start(Target, 2)
						_G.AddState(Target, "JumpLock", 2)
						_G.AddState(Target, "WalkspeedLock", 2, 0)
						_G.AddState(Target, "Busy", 2, 0)
						if _G.HasBall(Target) then
							_G.AddState(Target, "NoPickup", 2)
							Football:Drop(Target)
							Football:Pickup(Character)
						end
					end)
				end

				Character:AddTag("Charged")
				task.delay(.2, function()
					Character:RemoveTag("Charged")
				end)
				_G.AddState(Target, "Stunned", 2)

				_G.AddState(Character, "Immune", 2)
				_G.AddState(Target, "Immune", 2)

				if _G.HasBall(Target) then
					_G.AddState(Target, "NoPickup", 2)
					Football:Drop(Target)
					Football:Pickup(Character)
				end


				--	_G.Ragdoll.Start(Target, 2)
				--	Knockback:Apply(Target, Character.HumanoidRootPart.CFrame.RightVector + Vector3.new(0, -1/6, 0) + -Character.HumanoidRootPart.CFrame.LookVector/6, 600, 1.3, true)
				--Character.Humanoid:SetStateEnabled(Enum.HumanoidStateType.PlatformStanding, false)
				--Character.Humanoid.PlatformStand = false
				Character.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Running, true)
				Character.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)

				Hitbox:Destroy()
				_G.RemoveState(Target, "Stunned")
			end
		end

		if not IsHeld then
			Hitbox = HitboxModule.Create(
				Client,
				"GutsRun",
				Vector3.new(3.5, 3.5, 3.5),
				CFrame.new(Vector3.new(0, 0, -1.5))
			)

			Hitbox:SetOnHit(HitFunction)

			Hitbox:Start()
		end
		
		_G.VFX("Guts", "ChargeEffect", Character)


		task.delay(0.4, function()
			Remotes.Combat.ClientSkill:FireClient(Client, "Guts Charge")
		end)

		local lastStep = tick()
		Connection = RunService.Heartbeat:Connect(function(dt)
			if ChargeEnded then Disconnect = true end
			if Disconnect then Connection:Disconnect() task.spawn(function() task.wait(.8) end) end

			if tick() - Start >= 1.1 and not Disconnect then
				Connection:Disconnect() --BV:Destroy()


				Character.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Running, true)
				Character.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)

				if Hitbox then
					Hitbox:Destroy()
				end

				Character:AddTag("Charged")
				task.delay(.2, function()
					Character:RemoveTag("Charged")
				end)
			end


			if (tick() - lastStep) >= .25 then
				lastStep = tick()
			end

			--Character.Humanoid:SetStateEnabled(Enum.HumanoidStateType.PlatformStanding, false)
		end)

		task.wait(1.1)
	end
end


module.Ability2 = function(Football, Client : Player)
	local Connection
	local Character = Client:IsA("Player") and Client.Character or Client
	if _G.IsInAir(Character) then _G.Notify(Client, "Can't use while in air") end

	if not workspace:HasTag("MatchStarted") then return end
	if _G.CheckState(Character) then return end
	if _G.GetTeam(Character) == "None" then return end
	if _G.Cooldown:Check(Character, "SecondSkill") then return end
	
	_G.Cooldown:Add(Character, "SecondSkill", 25)
	_G.AddState(Character, "WalkspeedLock", 1.2, 0)
	_G.AddState(Character, "JumpLock", 1.2)
	_G.AddState(Character, "Busy", 1.2)
	_G.VFX("General", "Glow", Character, Color3.fromRGB(113, 0, 0))
	_G.VFX("Guts", "Warn", Character)

	_G.AddTag(Character, "Counter", 1.2)

	local spawnAnim = _G.AnimLoad(Character.Humanoid, "rbxassetid://123794065270259")
	_G.AnimPlay(Character.Humanoid, spawnAnim, .1)
	_G.SoundPlay(Character.HumanoidRootPart, "rbxassetid://132374478484769", game.SoundService.Master.SFX)
	_G.SoundPlay(Character.HumanoidRootPart, "rbxassetid://72538730431652", game.SoundService.Master.Voicelines)

	for _, particle in GutsFolder.Outline:GetChildren() do
		local Clone = particle:Clone()
		Clone.Name = "Outline"
		Clone.Parent = Character["Right Arm"]
		Clone = Clone:Clone()
		Clone.Parent = Character["Left Arm"]
		Clone:AddTag("GutsOutline"..Client.Name)

		Debris:AddItem(Clone, 1.2) 
	end
	_G.VFX("Guts", "AuraEnable", Character)

	local Doing = false

	local function CounterFunction(Name)
		if not Doing then
			local EnemyPlayer = game.Players:FindFirstChild(Name)
			local Enemy = game.Players:FindFirstChild(Name).Character
			
			_G.AddState(Character, "WalkspeedLock", 2.9, 0)
			_G.AddState(Character, "JumpLock", 2.9)
			_G.AddState(Character, "Busy", 2.9)
			_G.AddState(Character, "Immune", 2.9)
			
			_G.AddState(Enemy, "WalkspeedLock", 2.9, 0)
			_G.AddState(Enemy, "JumpLock", 2.9)
			_G.AddState(Enemy, "Busy", 2.9)
			_G.AddState(Enemy, "Immune", 3.9)

			Doing = true

			spawnAnim:Stop()

			Enemy.Humanoid:Move(Vector3.zero)
			
			local EHRP = Enemy.HumanoidRootPart
			EHRP:SetNetworkOwnershipAuto(false)
			EHRP.Position = Character.HumanoidRootPart.Position

			local Weld = Instance.new("Motor6D")
			Weld.Parent = Character.HumanoidRootPart
			Weld.C0 = CFrame.new(Vector3.new(0, 0, -3.4))
			Weld.Name = "GrabWeld"
			Weld.Part0 = Character.HumanoidRootPart
			Weld.Part1 = EHRP

			local VFX1 = GutsFolder.Skill2.counterpickup:Clone()
			VFX1:PivotTo(CFrame.new(EHRP.Position) * CFrame.new(Vector3.new(0, 2, -2.1)))
			VFX1:AddTag("GutsCounter1"..Client.Name)
			VFX1.Parent = workspace.VFX

			local VFX2 = GutsFolder.Skill2.counterslam:Clone()
			VFX2:PivotTo(CFrame.new(EHRP.Position) * CFrame.new(Vector3.new(0, 2, -3)))
			VFX2:AddTag("GutsCounter2"..Client.Name)
			VFX2.Parent = workspace.VFX

			local AttackAnim = _G.AnimLoad(Character.Humanoid, "rbxassetid://78549546034673")
			AttackAnim.Looped = false
			AttackAnim.Priority = Enum.AnimationPriority.Action3
			_G.AnimPlay(Character.Humanoid, AttackAnim, .1)

			_G.SoundPlay(Character.HumanoidRootPart, "rbxassetid://102788075632358", game.SoundService.Master.SFX)
	
			local spawnAnim2 = _G.AnimLoad(Enemy.Humanoid, "rbxassetid://109578741871578")
			spawnAnim2.Looped = false
			spawnAnim2:Play()

			task.spawn(function()
				task.wait(1 + 32/60)
				_G.VFX("Guts", "CounterPickup", Character)
				task.wait((84-82)/60)
				_G.VFX("Guts", "CounterSlam", Character)
			end)

			task.wait(85/60)
			Weld:Destroy()
			_G.Ragdoll.Start(Enemy, 3)
			_G.AddState(Enemy, "WalkspeedLock", .9, 3)
			
			task.delay(1, function()
				EHRP.Anchored = true
				task.wait()
				Enemy:PivotTo(CFrame.new(EHRP.Position) * CFrame.new(Vector3.new(0, 0, -2.1)))
				EHRP.Anchored = false
				EHRP:SetNetworkOwner(EnemyPlayer)
				EHRP:SetNetworkOwnershipAuto(true)
				EHRP.RootJoint.C0 = CFrame.Angles(math.rad(90), math.rad(180), 0)
				EHRP.RootJoint.C1 = CFrame.Angles(math.rad(90), math.rad(180), 0)
			end)

			task.wait(1.5)

			VFX1:Destroy()
			VFX2:Destroy()
		end
	end

	local Start = tick()

	Connection = RunService.Heartbeat:Connect(function(dt)
		if tick() - Start >= 1.2 then
			Character:RemoveTag("Counter")
			Connection:Disconnect()
		end

		if Character:GetAttribute("Countered") then
			CounterFunction(Character:GetAttribute("Countered"))
		end
	end)
end

module.Ability3 = function(Football, Client)
	local MainCharacter = Client.Character
	if not workspace:HasTag("MatchStarted") then return end
	if not _G.HasBall(MainCharacter) then return end
	if _G.CheckState(MainCharacter) then return end
	if math.abs(_G.GetTouchdown(MainCharacter).Position.X - MainCharacter.HumanoidRootPart.Position.X) > 105 then return end
	if not MainCharacter:HasTag("Awakened") then return end
	if _G.IsInAir(MainCharacter) then return end
	if workspace.OngoingCutscene.Value then return end
	if not MainCharacter:HasTag("AwakenSkill") then return end	

	MainCharacter:RemoveTag("AwakenSkill")
	
	local hrp = MainCharacter.HumanoidRootPart
	
	local pos = hrp.Position
	local _, y, _ = hrp.CFrame:ToOrientation()

	local StartPos = CFrame.new(pos.X, 23, pos.Z) * CFrame.Angles(0, y, 0)
	
	workspace.OngoingCutscene.Value = true
	workspace.HideBall.Value = true
	_G.Cutscene:Start(StartPos, "GutsUltimate", 8, MainCharacter, StartPos)
	
	task.delay(15, function()
		workspace.OngoingCutscene.Value = false
		workspace.HideBall.Value = false
		_G.Cutscene:Stop()
		_G.AddState(MainCharacter, "Immune", 2)
	end)
	
end

module.Awaken = function(Football, Client)
	local MainCharacter = Client.Character
	if not workspace:HasTag("MatchStarted") then return end
	if not _G.HasBall(MainCharacter) then return end
	if _G.CheckState(MainCharacter) then return end
	if _G.IsInAir(MainCharacter) then return end
	if _G.CheckAwaken(MainCharacter) < 100 or MainCharacter:HasTag("Awakened") then return end
	if workspace.OngoingCutscene.Value then return end

	local hrp = MainCharacter.HumanoidRootPart

	local pos = hrp.Position
	local _, y, _ = hrp.CFrame:ToOrientation()

	local StartPos = CFrame.new(pos.X, 23, pos.Z) * CFrame.Angles(0, y, 0)

	workspace.OngoingCutscene.Value = true
	_G.Cutscene:Start(StartPos, "GutsAwaken", 2, MainCharacter, StartPos)
	
	task.wait(14)
	MainCharacter:AddTag("Awakened")
	MainCharacter:AddTag("AwakenSkill")
	_G.VFX("Guts", "AwakenedAura", MainCharacter)
	workspace.OngoingCutscene.Value = false
	_G.Cutscene:Stop()
	_G.AddState(MainCharacter, "Immune", 2)

	for _, v in pairs(GutsFolder.Armor.Armor:GetChildren()) do
		local vClone = v:Clone()
		vClone.Parent = MainCharacter:FindFirstChild(v.Name)
		vClone.CFrame = MainCharacter:FindFirstChild(v.Name).CFrame
		local weld = Instance.new("Motor6D", vClone)
		weld.Part0 = MainCharacter:FindFirstChild(v.Name)
		weld.Part1 = vClone
		weld:AddTag("IgnoreMotor")
		vClone:AddTag("AwakenedOutfit")
	end

	for _, v in pairs(MainCharacter:GetChildren()) do
		if v:IsA("Accessory") or v:IsA("Hat") then
			for _, j in pairs(v:GetDescendants()) do
				if j:IsA("BasePart") then
					j:SetAttribute("OriginalTransparency", j.Transparency)
					j.Transparency = 1
					j:AddTag("DontShow")
				end
			end
		end
	end

	for _, v in pairs(MainCharacter:GetDescendants()) do
		if v.Name == "Suit" and v:IsA("BasePart") then
			v.Transparency = 1
			v:AddTag("DontShow")
		end
	end
	
	task.spawn(function()
		repeat task.wait(.1) until not MainCharacter:HasTag("Awakened")
		for _, v in pairs(game:GetService("CollectionService"):GetTagged("AwakenedOutfit")) do
			if v then v:Destroy() end
		end
		
		for _, v in pairs(MainCharacter:GetDescendants()) do
			if v and v.Name == "Suit" and v:IsA("BasePart") then
				v.Transparency = 0
				v:RemoveTag("DontShow")
			end
		end

		for _, v in pairs(MainCharacter:GetChildren()) do
			if v and v:IsA("Accessory") then
				for _, j in pairs(v:GetDescendants()) do
					if j and j:IsA("BasePart") then
						j.Transparency = j:GetAttribute("OriginalTransparency")
						j:RemoveTag("DontShow")
					end
				end
			end
		end
	end)
end

return module
