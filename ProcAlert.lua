-- ProcAlert: два ряда иконок в центре экрана.
--  * Нижний ряд — сработавшие способности (Превосходство, Казнь и т.д.), крупные иконки.
--    Показываются, пока условие выполнено; при нехватке ярости — тусклые и синеватые,
--    как кнопка на панели команд.
--  * Верхний ряд — обычные удары, которые можно применить прямо сейчас (хватает ярости,
--    нет перезарядки, цель в зоне досягаемости), иконки поменьше.
--  * В обоих рядах только то, что применяется в текущей стойке.
-- Пока ничего не сработало, обычные удары стоят на месте нижнего ряда; когда срабатывает
-- способность, они плавно уезжают вверх, а на их место встают сработавшие.

-- Номера заклинаний; названия берутся из клиента (GetSpellInfo), поэтому совпадают с русским переводом.
-- Стойки: стойка, в которой удар применяется. Без stances — в любой стойке.
-- В другой стойке иконка не показывается; переключились — иконка уходит.
local BATTLE, DEFENSIVE, BERSERKER = "battle", "defensive", "berserker"
local STANCE_SPELLS = { [BATTLE] = 2457, [DEFENSIVE] = 71, [BERSERKER] = 2458 }

-- buff — эффект таланта на вас, открывающий удар; пока он висит, под иконкой отсчёт секунд,
-- в конце иконка мигает. buffOnly — показывать удар только при этом эффекте.
local PROCS = {
	{ id = 7384,  stances = { BATTLE }, buff = 60503 },            -- Превосходство; эффект «Вкус крови» (Taste for Blood)
	{ id = 5308,  stances = { BATTLE, BERSERKER }, buff = 52437 }, -- Казнь; эффект «Внезапная смерть» (Sudden Death)
	{ id = 6572,  stances = { DEFENSIVE } },                       -- Реванш (Revenge): после блока, парирования или уклонения
	{ id = 34428, stances = { BATTLE, BERSERKER } },               -- Победный раж (Victory Rush): после убийства
	{ id = 1464,  buff = 46916, buffOnly = true },                 -- Мощный удар мгновенный; эффект «Мощный удар!» (Bloodsurge)
	{ id = 23922, buff = 50227, buffOnly = true },                 -- Мощный удар щитом бесплатно; эффект «Щит и меч» (Sword and Board)
}

-- Обычные удары в порядке показа. skipDebuff — не показывать, если ваш дебафф с этим
-- заклинанием уже висит на цели (иначе иконка торчала бы всегда).
-- Прерывания: показываются крупно над рядами, когда цель или фокус (враг) читает заклинание,
-- которое можно сбить. reflect — только если заклинание летит в вас.
local KICKS = {
	{ id = 6552,  stances = { BERSERKER } },                       -- Зуботычина (Pummel)
	{ id = 72,    stances = { BATTLE, DEFENSIVE } },               -- Удар щитом (Shield Bash), нужен щит
	{ id = 12809 },                                                -- Оглушающий удар (Concussion Blow), талант Защиты
	{ id = 23920, stances = { BATTLE, DEFENSIVE }, reflect = true }, -- Отражение заклинания (Spell Reflection), нужен щит
}

local REGULAR = {
	{ id = 12294 },                                         -- Смертельный удар (Mortal Strike)
	{ id = 23881 },                                         -- Кровожадность (Bloodthirst)
	{ id = 23922 },                                         -- Мощный удар щитом (Shield Slam)
	{ id = 1680,  stances = { BERSERKER } },                -- Вихрь (Whirlwind)
	{ id = 1464 },                                          -- Мощный удар (Slam)
	{ id = 78 },                                            -- Удар героя (Heroic Strike)
	{ id = 845 },                                           -- Рассекающий удар (Cleave)
	{ id = 6343,  stances = { BATTLE, DEFENSIVE }, skipDebuff = true }, -- Удар грома (Thunder Clap)
	{ id = 772,   stances = { BATTLE, DEFENSIVE }, skipDebuff = true }, -- Кровопускание (Rend)
	{ id = 20252, stances = { BERSERKER } },                -- Перехват (Intercept)
}

local CHECK_INTERVAL = 0.1 -- как часто проверять доступность, сек
local PROC_SIZE = 52       -- размер иконок сработавших способностей
local REGULAR_SIZE = 36    -- размер иконок обычных ударов
local KICK_SIZE = 60       -- размер иконок прерываний
local KICK_Y = 125         -- высота ряда прерываний над нижним рядом
local ROW_SPACING = 14     -- расстояние между рядами по вертикали
local DEFAULT_GAP = 18     -- расстояние между иконками в ряду; меняется командой /pa gap <число>
local SLIDE_SPEED = 10     -- скорость сдвига (больше — быстрее)
local POP_TIME = 0.25      -- длительность «пульса» при появлении сработавшей способности, сек
local POP_SCALE = 1.5      -- во сколько раз иконка больше в начале «пульса»
local FADE_IN = 0.15
local FADE_OUT = 0.35
local BLINK_TIME = 1.5     -- за сколько секунд до конца эффекта иконка начинает мигать
local NO_RAGE_ALPHA = 0.45 -- прозрачность сработавшей способности при нехватке ярости
local GCD_MAX = 1.6        -- перезарядка короче — это общая (GCD), её не считаем
local TEST_TIME = 3        -- сколько держатся иконки в /pa test, сек

-- Защитные способности: колонка слева от персонажа в оборонительной стойке при низком здоровье
local DEFENSIVE_CDS = {
	871,   -- Глухая оборона (Shield Wall)
	12975, -- Ни шагу назад (Last Stand)
	2565,  -- Блок щитом (Shield Block)
}
local DEF_HEALTH = 0.4     -- показывать, когда здоровья меньше этой доли
local DEF_SIZE = 56        -- размер иконок
local DEF_GAP = 10         -- расстояние между иконками по вертикали
local DEF_X, DEF_Y = -220, -40 -- центр колонки относительно центра экрана

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cffff7f00ProcAlert:|r " .. msg)
end

local function SoundEnabled() -- по умолчанию без звука; /pa sound
	return ProcAlertDB and ProcAlertDB.sound == true
end

local function KeysEnabled() -- по умолчанию клавиши не подписываются; /pa keys
	return ProcAlertDB and ProcAlertDB.showKeys == true
end

local function RegularEnabled() -- по умолчанию верхний ряд включён; /pa normal
	return not (ProcAlertDB and ProcAlertDB.regular == false)
end

local function DefEnabled() -- по умолчанию включено; /pa def
	return not (ProcAlertDB and ProcAlertDB.def == false)
end

local function GetGap()
	return (ProcAlertDB and ProcAlertDB.gap) or DEFAULT_GAP
end

-- Точка, вокруг которой центрируются ряды
local anchor = CreateFrame("Frame", "ProcAlertFrame", UIParent)
anchor:SetWidth(1)
anchor:SetHeight(1)
anchor:SetPoint("CENTER", UIParent, "CENTER", 0, 160)
anchor:SetFrameStrata("HIGH")

----------------------------------------------------------------------------------------------
-- Клавиша, назначенная на ячейку панели команд со способностью
-- Ячейки: 1-12 главная панель, 25-36 правая, 37-48 правая 2, 49-60 нижняя правая,
-- 61-72 нижняя левая, 73-120 — главная панель в стойках (подменяет 1-12)
local function BindingForSlot(slot)
	if slot >= 73 or slot <= 12 then return "ACTIONBUTTON" .. ((slot - 1) % 12 + 1) end
	if slot >= 61 then return "MULTIACTIONBAR1BUTTON" .. (slot - 60) end
	if slot >= 49 then return "MULTIACTIONBAR2BUTTON" .. (slot - 48) end
	if slot >= 37 then return "MULTIACTIONBAR4BUTTON" .. (slot - 36) end
	if slot >= 25 then return "MULTIACTIONBAR3BUTTON" .. (slot - 24) end
	return nil -- 13-24: вторая страница главной панели, своей клавиши нет
end

local function SlotHasSpell(slot, spellName)
	local actionType, id, subType, globalID = GetActionInfo(slot)
	if actionType == "spell" then
		return (globalID and GetSpellInfo(globalID) == spellName)
			or (id and GetSpellInfo(id) == spellName)
			or (id and GetSpellName(id, subType or BOOKTYPE_SPELL) == spellName)
	elseif actionType == "macro" then
		return GetMacroSpell(id) == spellName
	end
end

local function FindKey(spellName)
	if not KeysEnabled() then return nil end
	local order = {}
	local bonus = GetBonusBarOffset() -- 1-3: стойки воина
	if bonus and bonus > 0 then
		local first = 72 + (bonus - 1) * 12
		for s = first + 1, first + 12 do order[#order + 1] = s end
	else
		for s = 1, 12 do order[#order + 1] = s end
	end
	for s = 25, 72 do order[#order + 1] = s end
	for s = 1, 12 do order[#order + 1] = s end
	for _, slot in ipairs(order) do
		if HasAction(slot) and SlotHasSpell(slot, spellName) then
			local command = BindingForSlot(slot)
			local key = command and GetBindingKey(command)
			if key then return GetBindingText(key, "KEY_", 1) end
		end
	end
end

----------------------------------------------------------------------------------------------
-- Ряды иконок
local function NewRow(size, keyFont, ordered)
	return { size = size, keyFont = keyFont, ordered = ordered, items = {}, bySpell = {}, pool = {}, y = 0, targetY = 0 }
end
local procRow = NewRow(PROC_SIZE, 18, false)       -- порядок появления
local regularRow = NewRow(REGULAR_SIZE, 14, true)  -- порядок как в списке REGULAR
local kickRow = NewRow(KICK_SIZE, 18, false)       -- прерывания
local rows = { procRow, regularRow, kickRow }

local regularOrder = {}
for i, r in ipairs(REGULAR) do regularOrder[r.id] = i end

local function CreateItem(row)
	local f = CreateFrame("Frame", nil, anchor)
	f:SetWidth(row.size)
	f:SetHeight(row.size)
	f.icon = f:CreateTexture(nil, "ARTWORK")
	f.icon:SetPoint("CENTER", f, "CENTER", 0, 0)
	f.key = f:CreateFontString(nil, "OVERLAY")
	f.key:SetFont("Fonts\\FRIZQT__.TTF", row.keyFont, "THICKOUTLINE")
	f.key:SetPoint("TOP", f, "BOTTOM", 0, -4)
	f.key:SetTextColor(1, 1, 1)
	f.cd = CreateFrame("Cooldown", nil, f) -- затемнение-«часы», как на кнопке панели
	f.cd:SetAllPoints(f)
	local over = CreateFrame("Frame", nil, f) -- отсчёт эффекта поверх «часов»
	over:SetAllPoints(f)
	over:SetFrameLevel(f.cd:GetFrameLevel() + 1)
	f.timer = over:CreateFontString(nil, "OVERLAY")
	f.timer:SetFont("Fonts\\FRIZQT__.TTF", math.floor(row.size * 0.4), "THICKOUTLINE")
	f.timer:SetPoint("CENTER", f, "CENTER", 0, 0)
	f.timer:SetTextColor(1, 0.85, 0)
	f.rage = over:CreateFontString(nil, "OVERLAY") -- сколько ярости есть от нужной, при нехватке
	f.rage:SetFont("Fonts\\FRIZQT__.TTF", math.floor(row.size * 0.3), "THICKOUTLINE")
	f.rage:SetPoint("BOTTOM", f, "BOTTOM", 0, 2)
	f.rage:SetTextColor(0.6, 0.75, 1)
	return f
end

local function Layout(row)
	if row.ordered then
		table.sort(row.items, function(a, b) return (regularOrder[a.spellID] or 0) < (regularOrder[b.spellID] or 0) end)
	end
	local gap, total = GetGap(), 0
	for i, f in ipairs(row.items) do
		total = total + row.size + (i > 1 and gap or 0)
	end
	local x = -total / 2
	for _, f in ipairs(row.items) do
		f.targetX = x + row.size / 2
		if not f.x then f.x = f.targetX end -- новая иконка сразу на своём месте
		x = x + row.size + gap
	end
end

local function AddItem(row, spellID, name, texture, pop)
	local f = tremove(row.pool) or CreateItem(row)
	f.spellID = spellID
	f.spellName = name
	f.icon:SetTexture(texture)
	f.key:SetText(FindKey(name) or "")
	f.bornAt = GetTime()
	f.pop = pop
	f.alpha = 0
	f.x = nil
	f.removing = false
	f.noMana = false
	f.blocked = false
	f.cdStart = nil
	f.cd:Hide()
	f.buffExpires = nil
	f.timer:SetText("")
	f.rage:SetText("")
	f.icon:SetAlpha(1)
	f.expiresAt = nil
	f:SetAlpha(0)
	f:Show()
	row.items[#row.items + 1] = f
	row.bySpell[spellID] = f
	Layout(row)
	if pop and SoundEnabled() then PlaySound("RaidWarning") end
	return f
end

local function RemoveItem(row, f)
	for i, v in ipairs(row.items) do
		if v == f then tremove(row.items, i) break end
	end
	if row.bySpell[f.spellID] == f then row.bySpell[f.spellID] = nil end
	f:Hide()
	row.pool[#row.pool + 1] = f
	Layout(row)
end

-- Есть ли в ряду иконки, которые не исчезают
local function HasVisible(row)
	for _, f in ipairs(row.items) do
		if not f.removing then return true end
	end
	return false
end

----------------------------------------------------------------------------------------------
-- Анимация: сдвиг рядов и иконок, «пульс», появление/исчезновение, вид при нехватке ярости
anchor:SetScript("OnUpdate", function(_, elapsed)
	local now = GetTime()
	local k = math.min(1, elapsed * SLIDE_SPEED)

	-- обычные удары поднимаются над сработавшими, если те есть
	procRow.targetY = 0
	kickRow.targetY = KICK_Y
	regularRow.targetY = HasVisible(procRow) and (PROC_SIZE / 2 + ROW_SPACING + REGULAR_SIZE / 2) or 0

	for _, row in ipairs(rows) do
		row.y = row.y + (row.targetY - row.y) * k
		for i = #row.items, 1, -1 do
			local f = row.items[i]
			if f.expiresAt and now >= f.expiresAt then f.removing = true end

			f.x = f.x + (f.targetX - f.x) * k
			f:ClearAllPoints()
			f:SetPoint("CENTER", anchor, "CENTER", f.x, row.y)

			local size = row.size
			local age = now - f.bornAt
			if f.pop and age < POP_TIME then
				size = row.size * (POP_SCALE - (POP_SCALE - 1) * (age / POP_TIME))
			end
			f.icon:SetWidth(size)
			f.icon:SetHeight(size)

			local dim = f.cdStart or f.noMana or f.blocked
			local targetAlpha = f.removing and 0 or (dim and NO_RAGE_ALPHA or 1)
			local step = elapsed / (targetAlpha < f.alpha and FADE_OUT or FADE_IN)
			if f.alpha < targetAlpha then
				f.alpha = math.min(targetAlpha, f.alpha + step)
			else
				f.alpha = math.max(targetAlpha, f.alpha - step)
			end
			f:SetAlpha(f.alpha)

			if f.cdStart or f.blocked then
				f.icon:SetVertexColor(0.4, 0.4, 0.4) -- на перезарядке: серая
			elseif f.noMana then
				f.icon:SetVertexColor(0.5, 0.5, 1) -- как кнопка на панели при нехватке ярости
			else
				f.icon:SetVertexColor(1, 1, 1)
			end

			-- отсчёт эффекта таланта и мигание в конце
			local left = f.buffExpires and f.buffExpires > 0 and (f.buffExpires - now)
			if left and left > 0 then
				f.timer:SetText(left >= 3 and tostring(math.floor(left + 0.5)) or string.format("%.1f", left))
				f.icon:SetAlpha(left < BLINK_TIME and (0.55 + 0.45 * math.abs(math.sin(now * 8))) or 1)
			else
				f.timer:SetText("")
				f.icon:SetAlpha(1)
			end

			if f.removing and f.alpha <= 0 then
				RemoveItem(row, f)
			end
		end
	end
end)

-- Подписи клавиш обновляются при смене назначений, панелей или стойки
local function RefreshKeys()
	for _, row in ipairs(rows) do
		for _, f in ipairs(row.items) do
			f.key:SetText(FindKey(f.spellName) or "")
		end
	end
end
local keyWatcher = CreateFrame("Frame")
for _, event in ipairs({ "UPDATE_BINDINGS", "ACTIONBAR_SLOT_CHANGED", "UPDATE_BONUS_ACTIONBAR", "ACTIONBAR_PAGE_CHANGED" }) do
	keyWatcher:RegisterEvent(event)
end
keyWatcher:SetScript("OnEvent", RefreshKeys)

----------------------------------------------------------------------------------------------
-- Проверка доступности
local function HasEnemyTarget()
	return UnitExists("target") and not UnitIsDead("target") and UnitCanAttack("player", "target")
end

-- Текущая стойка воина: сравниваем название активной формы с названиями стоек из клиента
-- (номер формы зависит от того, какие стойки изучены, поэтому по номеру не определяем)
local stanceByName
local function CurrentStance()
	if not stanceByName then
		stanceByName = {}
		for key, spellID in pairs(STANCE_SPELLS) do
			local name = GetSpellInfo(spellID)
			if name then stanceByName[name] = key end
		end
	end
	local form = GetShapeshiftForm()
	if not form or form == 0 then return nil end
	local _, name = GetShapeshiftFormInfo(form)
	return name and stanceByName[name]
end

local function StanceAllows(stances)
	if not stances then return true end
	local current = CurrentStance()
	for _, s in ipairs(stances) do
		if s == current then return true end
	end
	return false
end

local function HasMyDebuff(name)
	for i = 1, 40 do
		local dName, _, _, _, _, _, _, caster = UnitDebuff("target", i)
		if not dName then return false end
		if dName == name and caster == "player" then return true end
	end
	return false
end

-- Перезарядка способности (без общей): начало и длительность или nil
local function CooldownOf(name)
	local start, duration = GetSpellCooldown(name)
	if start and start > 0 and duration and duration > GCD_MAX then return start, duration end
end

-- Иконка сработавшей способности на перезарядке — серая с «часами»
local function SetItemCooldown(f, start, duration)
	if start == f.cdStart then return end
	f.cdStart = start
	if start then
		f.cd:SetCooldown(start, duration)
		f.cd:Show()
	else
		f.cd:Hide()
	end
end

-- Ваш эффект с этим номером заклинания: true и время окончания (0 — бессрочный) или nil
local function MyBuff(spellID)
	local buffName = GetSpellInfo(spellID)
	for i = 1, 40 do
		local name, _, _, _, _, _, expires, _, _, _, id = UnitBuff("player", i)
		if not name then return nil end
		if id == spellID or (buffName and name == buffName) then return true, expires or 0 end
	end
end

-- Сколько ярости есть из нужной: "3/5" или "" (если стоимость неизвестна)
local function RageText(name)
	local cost = select(4, GetSpellInfo(name))
	if not cost or cost <= 0 then return "" end
	local rage = UnitPower and UnitPower("player", 1) or UnitMana("player")
	return rage .. "/" .. cost
end

-- Сработавшая способность: условие выполнено (даже если не хватает ярости)
local function ProcState(name)
	local usable, noMana = IsUsableSpell(name)
	return (usable or noMana) and true or false, noMana and true or false
end

-- Обычный удар: можно применить прямо сейчас
local function RegularReady(name, r)
	if not StanceAllows(r.stances) then return false end
	if not IsUsableSpell(name) then return false end -- не хватает ярости
	if CooldownOf(name) then return false end
	if IsSpellInRange(name, "target") == 0 then return false end
	if r.skipDebuff and HasMyDebuff(name) then return false end
	return true
end

local function Known(spellID)
	local name, _, texture = GetSpellInfo(spellID)
	if name and GetSpellInfo(name) then return name, texture end -- есть в книге заклинаний
end

----------------------------------------------------------------------------------------------
-- Защитные способности: все изученные из DEFENSIVE_CDS, с видом доступности:
-- яркая — можно применить, синеватая — не хватает ярости, серая с «часами» — перезарядка
-- или нельзя применить (например, нет щита)
local defFrame = CreateFrame("Frame", "ProcAlertDefFrame", UIParent)
defFrame:SetWidth(1)
defFrame:SetHeight(1)
defFrame:SetPoint("CENTER", UIParent, "CENTER", DEF_X, DEF_Y)
defFrame:SetFrameStrata("HIGH")
defFrame:SetAlpha(0)
defFrame.targetAlpha = 0
local defItems = {}
local defTestUntil = 0

defFrame:SetScript("OnUpdate", function(self, elapsed)
	local alpha = self:GetAlpha()
	if alpha < self.targetAlpha then
		self:SetAlpha(math.min(self.targetAlpha, alpha + elapsed / FADE_IN))
	elseif alpha > self.targetAlpha then
		self:SetAlpha(math.max(self.targetAlpha, alpha - elapsed / FADE_OUT))
	end
end)

local function DefItem(i)
	local f = defItems[i]
	if not f then
		f = CreateFrame("Frame", nil, defFrame)
		f:SetWidth(DEF_SIZE)
		f:SetHeight(DEF_SIZE)
		f.icon = f:CreateTexture(nil, "ARTWORK")
		f.icon:SetAllPoints(f)
		f.cd = CreateFrame("Cooldown", nil, f)
		f.cd:SetAllPoints(f)
		f.cd:Hide()
		defItems[i] = f
	end
	return f
end

local function LowHealth()
	local max = UnitHealthMax("player")
	return max and max > 0 and not UnitIsDeadOrGhost("player") and UnitHealth("player") / max < DEF_HEALTH
end

local function UpdateDefensive()
	local active = GetTime() < defTestUntil
		or (DefEnabled() and CurrentStance() == DEFENSIVE and LowHealth())
	defFrame.targetAlpha = active and 1 or 0
	if not active and defFrame:GetAlpha() == 0 then return end

	local n = 0
	for _, spellID in ipairs(DEFENSIVE_CDS) do
		local name, texture = Known(spellID)
		if name then
			n = n + 1
			local f = DefItem(n)
			f.icon:SetTexture(texture)
			SetItemCooldown(f, CooldownOf(name))
			local usable, noMana = IsUsableSpell(name)
			if f.cdStart or not (usable or noMana) then
				f.icon:SetVertexColor(0.4, 0.4, 0.4)
				f:SetAlpha(NO_RAGE_ALPHA)
			elseif noMana then
				f.icon:SetVertexColor(0.5, 0.5, 1)
				f:SetAlpha(NO_RAGE_ALPHA)
			else
				f.icon:SetVertexColor(1, 1, 1)
				f:SetAlpha(1)
			end
			f:ClearAllPoints()
			f:SetPoint("CENTER", defFrame, "CENTER", 0, ((#DEFENSIVE_CDS + 1) / 2 - n) * (DEF_SIZE + DEF_GAP))
			f:Show()
		end
	end
	for i = n + 1, #defItems do defItems[i]:Hide() end
end

local checker = CreateFrame("Frame")
local elapsedTotal = 0
checker:SetScript("OnUpdate", function(_, elapsed)
	elapsedTotal = elapsedTotal + elapsed
	if elapsedTotal < CHECK_INTERVAL then return end
	elapsedTotal = 0
	local enemy = HasEnemyTarget()
	UpdateDefensive()

	for _, p in ipairs(PROCS) do
		local spellID = p.id
		local name, texture = Known(spellID)
		if name then
			local ready, noMana = false, false
			local hasBuff, buffExpires
			if p.buff then hasBuff, buffExpires = MyBuff(p.buff) end
			if enemy and StanceAllows(p.stances) and (hasBuff or not p.buffOnly) then
				ready, noMana = ProcState(name)
			end
			local f = procRow.bySpell[spellID]
			if f and f.expiresAt then
				-- иконка из /pa test: не трогаем
			elseif ready then
				f = f or AddItem(procRow, spellID, name, texture, true)
				f.removing = false
				f.noMana = noMana
				f.rage:SetText(noMana and RageText(name) or "")
				f.buffExpires = hasBuff and buffExpires or nil
				SetItemCooldown(f, CooldownOf(name))
			elseif f then
				f.removing = true
			end
		end
	end

	-- Прерывания: чьё заклинание сбивать — цели, иначе фокуса
	local castUnit, castEnds
	for _, unit in ipairs({ "target", "focus" }) do
		if UnitExists(unit) and UnitCanAttack("player", unit) and not UnitIsDead(unit) then
			local name, _, _, _, _, endTime, _, _, notInterruptible = UnitCastingInfo(unit)
			if not name then
				name, _, _, _, _, endTime, _, notInterruptible = UnitChannelInfo(unit)
			end
			if name and not notInterruptible then
				castUnit, castEnds = unit, endTime / 1000
				break
			end
		end
	end
	for _, kk in ipairs(KICKS) do
		local name, texture = Known(kk.id)
		if name then
			local ready = castUnit and StanceAllows(kk.stances)
				and (not kk.reflect or UnitIsUnit(castUnit .. "target", "player"))
			local f = kickRow.bySpell[kk.id]
			if f and f.expiresAt then
				-- иконка из /pa test: не трогаем
			elseif ready then
				local usable, noMana = IsUsableSpell(name)
				f = f or AddItem(kickRow, kk.id, name, texture, true)
				f.removing = false
				f.noMana = noMana and true or false
				f.rage:SetText(noMana and RageText(name) or "")
				-- серая: нельзя применить (нет щита) или цель далеко
				f.blocked = not (usable or noMana) or (not kk.reflect and IsSpellInRange(name, castUnit) == 0)
				f.buffExpires = castEnds -- отсчёт: сколько осталось до конца заклинания врага
				SetItemCooldown(f, CooldownOf(name))
			elseif f then
				f.removing = true
			end
		end
	end

	for _, r in ipairs(REGULAR) do
		local name, texture = Known(r.id)
		if name then
			local proc = procRow.bySpell[r.id] -- уже показан крупно в нижнем ряду
			local ready = enemy and RegularEnabled() and not (proc and not proc.removing) and RegularReady(name, r)
			local f = regularRow.bySpell[r.id]
			if f and f.expiresAt then
				-- иконка из /pa test: не трогаем
			elseif ready then
				f = f or AddItem(regularRow, r.id, name, texture, false)
				f.removing = false
			elseif f then
				f.removing = true
			end
		end
	end
end)

----------------------------------------------------------------------------------------------
-- Команды
local function Test()
	-- сначала обычные удары, затем по очереди сработавшие — видно, как обычные уезжают вверх
	for _, r in ipairs(REGULAR) do
		local name, texture = Known(r.id)
		if name and not regularRow.bySpell[r.id] then
			AddItem(regularRow, r.id, name, texture, false).expiresAt = GetTime() + TEST_TIME + 2
		end
	end
	defTestUntil = GetTime() + TEST_TIME + 2
	for _, kk in ipairs(KICKS) do
		local name, texture = Known(kk.id)
		if name and not kickRow.bySpell[kk.id] then
			local f = AddItem(kickRow, kk.id, name, texture, true)
			f.expiresAt = GetTime() + TEST_TIME + 2
			f.buffExpires = f.expiresAt
		end
	end
	local delay = 1
	for i, p in ipairs(PROCS) do
		local spellID = p.id
		local name, _, texture = GetSpellInfo(spellID)
		if name then
			local startAt = GetTime() + delay
			local timer = CreateFrame("Frame")
			timer:SetScript("OnUpdate", function(self)
				if GetTime() < startAt then return end
				self:SetScript("OnUpdate", nil)
				if procRow.bySpell[spellID] then return end
				local f = AddItem(procRow, spellID, name, texture, true)
				f.expiresAt = GetTime() + TEST_TIME
				f.noMana = (i == 2)
				if f.noMana then f.rage:SetText("3/5") end
				if p.buff then f.buffExpires = f.expiresAt end
			end)
			delay = delay + 0.6
		end
	end
end

-- /pa — справка; /pa test, /pa sound, /pa keys, /pa normal, /pa gap <число>
SLASH_PROCALERT1 = "/pa"
SlashCmdList["PROCALERT"] = function(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	ProcAlertDB = ProcAlertDB or {}
	local function onoff(v) return v and "вкл" or "выкл" end
	if msg == "sound" then
		ProcAlertDB.sound = not SoundEnabled() and true or false
		Print("звук: " .. onoff(ProcAlertDB.sound) .. ".")
	elseif msg == "keys" then
		ProcAlertDB.showKeys = not KeysEnabled() and true or false
		RefreshKeys()
		Print("подписи клавиш: " .. onoff(ProcAlertDB.showKeys) .. ".")
	elseif msg == "normal" then
		ProcAlertDB.regular = not RegularEnabled()
		Print("ряд обычных ударов: " .. onoff(ProcAlertDB.regular) .. ".")
	elseif msg:match("^gap") then
		local n = tonumber(msg:match("^gap%s+(%-?%d+)$"))
		if n and n >= 0 and n <= 200 then
			ProcAlertDB.gap = n
			Layout(procRow)
			Layout(regularRow)
			Print("расстояние между иконками: " .. n .. ".")
		else
			Print("укажите число от 0 до 200, например /pa gap 18 (сейчас: " .. GetGap() .. ").")
		end
	elseif msg == "def" then
		ProcAlertDB.def = not DefEnabled()
		Print("защитные способности при здоровье ниже " .. (DEF_HEALTH * 100) .. "%: " .. onoff(ProcAlertDB.def) .. ".")
	elseif msg == "test" then
		Test()
	else
		Print("/pa test — пример; /pa normal — ряд обычных ударов (" .. onoff(RegularEnabled()) .. "); /pa def — защитные (" .. onoff(DefEnabled()) .. "); /pa keys — клавиши ("
			.. onoff(KeysEnabled()) .. "); /pa sound — звук (" .. onoff(SoundEnabled()) .. "); /pa gap <число> — расстояние (" .. GetGap() .. ").")
	end
end
