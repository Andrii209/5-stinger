--@name Stinger
--@author Arena
--@shared
--@precachemodel models/weapons/w_missile.mdl
--@precachemodel models/weapons/w_missile_closed.mdl

--[[
	Стингер (ПЗРК) для Starfall.

	Как работает:
	- Владелец чипа берёт weapon_rpg -> по центру прицела рисуется круг захвата.
	- В круг берётся живой игрок или техника (машины, кресла/поды, джепы и т.п.),
	  если цель видна (не за стеной). Круг краснеет, на цели появляется метка,
	  снизу пишется LOCK.
	- Выстрел с захватом -> вместо обычной ракеты летит самонаводящаяся ракета
	  с трассой, доворачивает к цели и взрывается.
	- Урон и радиус взрыва настраиваются двумя числами ниже.

	Ставится обычным Starfall-процессором. Владелец чипа = стрелок.
]]

-- ---------------------------------------------------------------- настройки
local DMG           = 120    -- урон в эпицентре взрыва
local BLAST_RADIUS  = 300    -- радиус взрыва (юниты)

-- ---------------------------------------------------------- прочие числа
local LOCK_ANGLE    = 8      -- половина угла круга захвата (градусы)
local LOCK_DIST     = 8000   -- максимальная дистанция захвата
local ROCKET_SPEED  = 1800   -- скорость ракеты (юнитов/сек)
local ROCKET_TURN   = 6      -- скорость доворота к цели
local ROCKET_LIFE   = 8      -- время жизни ракеты (сек)
local PROXIMITY     = 110    -- дистанция неконтактного подрыва
local SHOT_RANGE    = 220    -- насколько близко к стрелку считаем "свой" выстрел
local ROCKET_MODEL  = "models/weapons/w_missile.mdl"
local FALLBACK_MDL  = "models/weapons/w_missile_closed.mdl"

-- Всё, что подходит под эти классы, считается техникой-целью
local VEHICLE_CLASSES = {
	"prop_vehicle_*",   -- джепы, аирботы, кресла (prisoner_pod), машины и т.п.
	"simfphys_*",       -- simfphys-машины (если аддон стоит)
}

-- То, что не должно считаться техникой, даже если попало в список классов
local NOT_TARGET = {
	["prop_physics"] = true,
	["prop_physics_multiplayer"] = true,
	["prop_ragdoll"] = true,
	["prop_dynamic"] = true,
	["rpg_missile"] = true,
	["starfall_hologram"] = true,
	["starfall_prop"] = true,
	["starfall_processor"] = true,
	["starfall_screen"] = true,
}

-- ------------------------------------------------------ общие хелперы
local function centerOf(ent)
	local ok, mn, mx = pcall(ent.getCollisionBounds, ent)
	if ok and mn and mx then
		local center = ent:getPos() + (mn + mx) * 0.5
		local radius = (mx - mn):getLength() * 0.5
		return center, math.clamp(radius, 8, 512)
	end
	return ent:getPos(), 40
end

local function marksTarget(ent)
	if not ent or not ent:isValid() then return false end
	if ent:isPlayer() then return ent:isAlive() end
	return true
end

local function aimPointOf(ent)
	if ent:isPlayer() then return ent:getPos() + Vector(0, 0, 40), 32 end
	return centerOf(ent)
end

if SERVER then

	-- =============================================================== сервер
	local ownerPly = owner()

	local locked          -- есть захват (нужно клиенту)
	local target          -- захваченная цель (игрок или техника)
	local flying = false  -- наша ракета в воздухе
	local rPos, rDir      -- позиция и направление ракеты
	local rLife           -- остаток жизни
	local rTarget         -- цель ракеты
	local rVisual         -- голограмма-ракета (может отсутствовать)
	local rTrailT         -- таймер трассы

	local vehicles = {}   -- кэш техники (обновляется реже, чем скан)

	local function ownerOk()
		return ownerPly:isValid() and ownerPly:isAlive()
	end

	local function rpgHeld()
		if not ownerOk() then return false end
		local wep = ownerPly:getActiveWeapon()
		return wep ~= nil and wep:isValid() and wep:getClass() == "weapon_rpg"
	end

	------------------------------------------------------------------- сеть
	local lastSentEnt

	local function sendLock(state, ent)
		locked = state
		lastSentEnt = state and ent or nil
		if not ownerPly:isValid() then return end
		pcall(function()
			net.start("stinger_lock")
			net.writeBool(state)
			if state and ent then net.writeEntity(ent) end
			net.send(ownerPly)
		end)
	end

	------------------------------------------------------------------ цели
	local function refreshVehicles()
		local list, seen = {}, {}

		local function add(e)
			if not e or not e:isValid() or seen[e] then return end
			seen[e] = true

			local class = e:getClass()
			if NOT_TARGET[class] or e:isWeapon() or e:isPlayer() or e == chip() then return end
			if e:getSolid() == SOLID.NONE then return end

			list[#list + 1] = e
		end

		for _, class in ipairs(VEHICLE_CLASSES) do
			pcall(function()
				for _, e in ipairs(find.byClass(class)) do add(e) end
			end)
		end

		vehicles = list
	end

	local function visible(from, point, ent)
		local tr = trace.line(from, point, { ownerPly }, MASK.SOLID)
		return not tr.Hit or tr.Entity == ent
	end

	-- Насколько объект (с учётом его габаритов) попадает в конус прицела.
	-- Возвращает "запас" в градусах: <= 0 значит объект внутри круга.
	local function coneScore(eye, aim, point, radius, dist)
		local dot = ((point - eye) / dist):dot(aim)
		if dot <= 0 then return nil end

		local ang = math.deg(math.acos(math.clamp(dot, -1, 1)))
		local half = math.deg(math.asin(math.clamp(radius / dist, 0, 0.999)))
		return ang - half
	end

	local function findTarget()
		local eye = ownerPly:getShootPos()
		local aim = ownerPly:getAimVector()

		local best, bestScore

		local function consider(ent, point, radius, bonus)
			local dist = (point - eye):getLength()
			if dist <= 0 or dist > LOCK_DIST then return end

			local score = coneScore(eye, aim, point, radius, dist)
			if not score or score > LOCK_ANGLE then return end

			score = score - (bonus or 0) -- меньше = лучше
			if bestScore and score >= bestScore then return end
			if not visible(eye, point, ent) then return end

			best, bestScore = ent, score
		end

		-- игроки
		for _, ply in ipairs(find.allPlayers()) do
			if ply:isValid() and ply ~= ownerPly and ply:isAlive() then
				consider(ply, ply:getPos() + Vector(0, 0, 40), 32, 3)
			end
		end

		-- техника (машины, кресла/поды, джепы...)
		for _, veh in ipairs(vehicles) do
			if veh:isValid() then
				local point, radius = centerOf(veh)
				consider(veh, point, radius)
			end
		end

		return best
	end

	local syncT, vehT = 0, 0

	-- Скан 10 раз в секунду. Состояние отправляем при изменении и раз в секунду
	-- (чтобы клиент, загрузившийся позже, всё равно получил актуальный захват).
	timer.create("stinger_scan", 0.1, 0, function()
		syncT, vehT = syncT + 0.1, vehT + 0.1

		if vehT >= 0.4 or #vehicles == 0 then
			vehT = 0
			refreshVehicles()
		end

		if not rpgHeld() then
			target = nil
			if locked or syncT >= 1 then
				syncT = 0
				sendLock(false)
			end
			return
		end

		target = findTarget()
		local state = target ~= nil
		if state ~= (locked or false) or (state and lastSentEnt ~= target) or syncT >= 1 then
			syncT = 0
			sendLock(state, target)
		end
	end)

	------------------------------------------------------------------- взрыв
	local function explode(pos)
		pcall(effect.create, "Explosion", {
			origin = pos,
			magnitude = 1,
			scale = math.clamp(BLAST_RADIUS / 150, 0.2, 8),
		})
		pcall(sound.emitSound, "ambient/explosions/explode_4.wav", pos)

		-- Основной урон (на сервере обычно требует прав администратора)
		local ok = pcall(game.blastDamage, pos, BLAST_RADIUS, DMG)

		-- Запасной вариант: считаем урон сами, с ослаблением к краю радиуса
		if not ok then
			local okSphere, list = pcall(find.inSphere, pos, BLAST_RADIUS)
			if okSphere then
				for _, ent in ipairs(list) do
					if ent:isValid() and ent ~= ownerPly and (ent:isPlayer() or ent:isNPC()) then
						local frac = 1 - ent:getPos():getDistance(pos) / BLAST_RADIUS
						local dmg = DMG * frac
						if dmg > 1 then
							pcall(function()
								ent:applyDamage(dmg, ownerPly, nil, DAMAGE.BLAST, pos)
							end)
						end
					end
				end
			end
		end
	end

	------------------------------------------------------------------ ракета
	local function clearRocket()
		if rVisual and rVisual:isValid() then
			pcall(function() rVisual:remove() end)
		end
		flying = false
		rPos, rDir, rTarget, rTrailT = nil, nil, nil, nil
		rVisual, rLife = nil, nil
	end

	local function boom(pos)
		clearRocket()
		explode(pos)
	end

	local function spawnRocket(pos, dir, tgt)
		flying = true
		rPos, rDir, rTarget = pos, dir, tgt
		rLife, rTrailT = ROCKET_LIFE, 0

		local ang = dir:getAngle()
		local ok, holo = pcall(holograms.create, pos, ang, ROCKET_MODEL)
		if not ok or not holo then
			ok, holo = pcall(holograms.create, pos, ang, FALLBACK_MDL)
		end
		rVisual = (ok and holo) or nil
	end

	hook.add("Tick", "stinger_rocket", function()
		if not flying then return end
		if rVisual and not rVisual:isValid() then rVisual = nil end

		local dt = math.clamp(timer.frametime(), 0, 0.1)

		rLife = rLife - dt
		if rLife <= 0 then
			boom(rPos)
			return
		end

		-- доворот к цели (работает и для игроков, и для техники)
		local tgtPoint
		if marksTarget(rTarget) then
			tgtPoint = aimPointOf(rTarget)
			local want = (tgtPoint - rPos):getNormalized()
			rDir = (rDir + want * math.clamp(dt * ROCKET_TURN, 0, 1)):getNormalized()
		end

		local oldPos = rPos
		local newPos = rPos + rDir * (ROCKET_SPEED * dt)

		-- попадание в мир / проп / игрока / технику
		local tr = trace.line(oldPos, newPos, { ownerPly, chip() }, MASK.SHOT)
		if tr.Hit then
			boom(tr.HitPos)
			return
		end

		-- неконтактный взрыватель рядом с целью
		if tgtPoint and newPos:getDistance(tgtPoint) <= PROXIMITY then
			boom(newPos)
			return
		end

		rPos = newPos
		if rVisual then
			pcall(function()
				rVisual:setPos(newPos)
				rVisual:setAngles(rDir:getAngle())
			end)
		end

		-- трасса
		rTrailT = rTrailT - dt
		if rTrailT <= 0 then
			rTrailT = 0.03
			pcall(effect.create, "GaussTracer", { start = oldPos, origin = newPos })
		end
	end)

	-- Выстрел: если есть захват, заменяем обычную ракету на самонаводящуюся
	hook.add("OnEntityCreated", "stinger_shot", function(ent)
		if not ent:isValid() or ent:getClass() ~= "rpg_missile" then return end
		if not rpgHeld() then return end
		if ent:getPos():getDistance(ownerPly:getShootPos()) > SHOT_RANGE then return end

		local tgt = target
		if not marksTarget(tgt) then return end

		-- Убираем обычную ракету, иначе будет двойной взрыв.
		-- Если сервер запрещает удалять (проп-защита), просто не мешаем.
		local pos = ent:getPos()
		pcall(function() ent:remove() end)
		if ent:isValid() then return end

		-- одна ракета за раз
		if flying then return end

		spawnRocket(pos, (aimPointOf(tgt) - pos):getNormalized(), tgt)
	end)

else

	-- =============================================================== клиент
	local me = player()
	local isOwner = false

	local function checkOwner()
		local p, own = player(), owner()
		if p:isValid() and own:isValid() then
			return p:getSteamID() == own:getSteamID()
		end
		return false
	end

	isOwner = checkOwner()
	if isOwner then
		pcall(enableHud, nil, true) -- разрешаем чипу рисовать на своём HUD
	else
		-- подстраховка, если чип загрузился раньше игрока
		timer.simple(1, function()
			if checkOwner() then
				isOwner = true
				pcall(enableHud, nil, true)
			end
		end)
	end

	local locked = false
	local lockTarget = nil
	local hudFont
	local pulse = 0

	do
		local ok, font = pcall(render.createFont, "Roboto", 20, 700)
		if ok then hudFont = font end
	end

	net.receive("stinger_lock", function()
		locked = net.readBool()
		if locked then
			net.readEntity(function(ent)
				lockTarget = ent
			end)
		else
			lockTarget = nil
		end
	end)

	-- Круг захвата: конус вокруг прицела, спроецированный на экран.
	-- Так круг на HUD совпадает с тем, что проверяет сервер.
	local SEGMENTS = 32
	local PROJ_DIST = 2000
	local ringSize = 54

	local function ringPoints(eye, aim)
		local basis = aim:getAngle()
		local right, up = basis:getRight(), basis:getUp()
		local t = math.tan(math.rad(LOCK_ANGLE))

		local pts, center, bottom = {}, nil, nil
		for i = 0, SEGMENTS do
			local a = (i / SEGMENTS) * math.pi * 2
			local dir = (aim + right * (math.cos(a) * t) + up * (math.sin(a) * t)):getNormalized()
			local scr = (eye + dir * PROJ_DIST):toScreen()
			pts[i + 1] = scr
			if i == 0 then
				center = scr
				bottom = scr
			elseif scr.visible and scr.y > bottom.y then
				bottom = scr
			end
		end
		return pts, center, bottom
	end

	-- Радиус метки на экране под габариты цели
	local function screenRadius(point, radius, aim)
		local ok, right = pcall(function() return aim:getAngle():getRight() end)
		if not ok or not right then return ringSize * 0.5 end

		local a = point:toScreen()
		local b = (point + right * radius):toScreen()
		if not a.visible or not b.visible then return ringSize * 0.5 end
		return math.clamp(math.abs(b.x - a.x) + math.abs(b.y - a.y), 12, 220)
	end

	hook.add("drawhud", "stinger_hud", function()
		if not isOwner then return end

		local ply = player()
		if not ply:isValid() or not ply:isAlive() then return end

		local wep = ply:getActiveWeapon()
		if not wep or not wep:isValid() or wep:getClass() ~= "weapon_rpg" then return end

		local eye, aim = render.getEyePos(), render.getEyeVector()
		local pts, center, bottom = ringPoints(eye, aim)
		if not center or not center.visible then return end

		if locked then
			render.setColor(Color(255, 60, 60, 220))
		else
			render.setColor(Color(255, 255, 255, 120))
		end

		for i = 1, SEGMENTS do
			local a, b = pts[i], pts[i + 1]
			if a and b and a.visible and b.visible then
				render.drawLine(a.x, a.y, b.x, b.y)
			end
		end

		render.drawFilledCircle(center.x, center.y, 2)

		if locked then
			if hudFont then render.setFont(hudFont) end
			if bottom then
				render.drawSimpleText(bottom.x, bottom.y + 6, "LOCK", TEXT_ALIGN.CENTER, TEXT_ALIGN.TOP)
			end

			-- метка на цели (игрок или техника)
			if marksTarget(lockTarget) then
				local point, radius = aimPointOf(lockTarget)
				local scr = point:toScreen()
				if scr.visible then
					pulse = (pulse + timer.frametime() * 3) % 1

					local r = screenRadius(point, radius, aim) * (0.8 + pulse * 0.4)
					render.setColor(Color(255, 40, 40, 90 + math.floor(pulse * 120)))
					render.drawCircle(scr.x, scr.y, r)
					render.setColor(Color(255, 60, 60, 230))
					render.drawFilledCircle(scr.x, scr.y, 3)
				end
			end
		end
	end)

end
