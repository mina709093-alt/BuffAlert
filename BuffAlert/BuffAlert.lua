-- BuffAlert: 내가 관리하고 싶은 버프를 "현재 걸려 있는 버프 읽기"로 등록해 두면,
-- 그 버프가 사라질 때 화면에 아이콘을 띄우고 알림음을 울립니다.
--   /ba            설정창 열기/닫기
--   /ba set        지금 걸린 버프로 설정 (기존 목록 교체)
--   /ba add        지금 걸린 버프를 목록에 추가
--   /ba clear      목록 비우기
--   /ba test       알림음 듣기
--   /ba minimap    미니맵 아이콘 표시/숨김

local ADDON = "BuffAlert"
local PADX, CW = 14, 312
local ROWS = 9
local ICON = 48

-- 상수 스타일 색 (상수팩 공통 색)
local C_TEXT = { 0.93, 0.94, 0.96 }
local C_MUTED = { 0.55, 0.60, 0.63 }
local C_ACCENT = { 0.063, 0.816, 0.627 }
local C_BG = { 0.035, 0.055, 0.065 }
local C_PANEL = { 0.02, 0.035, 0.042 }
local C_BTN, C_BTN_HI = { 0.055, 0.085, 0.10 }, { 0.08, 0.12, 0.14 }
local C_SEL, C_SEL_HI = { 0.045, 0.32, 0.26 }, { 0.06, 0.40, 0.32 }
local C_BTN_EDGE = { 0.20, 0.25, 0.28 }
local BG_ALPHA = 0.92
local C_RED = { 0.90, 0.25, 0.22 }
local FONT_R = "Interface\\AddOns\\BuffAlert\\fonts\\MaruBuri-Regular.ttf"
local FONT_B = "Interface\\AddOns\\BuffAlert\\fonts\\MaruBuri-Bold.ttf"
local SOUND_FILE = "Interface\\AddOns\\BuffAlert\\ting.mp3"
local DEATH_SOUND = "Interface\\AddOns\\BuffAlert\\wakeUp.mp3"   -- 사망음 (기본 켜짐, 설정창 버튼 또는 /ba 사망음)

local db, frame, alerts
local state = {}        -- 버프 이름 -> true(있음) / false(없음) / nil(모름)
local instOf = {}       -- 버프 이름 -> 버프 인스턴스 번호
local expOf = {}        -- 버프 이름 -> 예상 종료 시각
local seenCombat, missTicks = {}, {}
local graceUntil = 0
local lastSound = 0
local offset = 0
local needEval = true
local missingNow = {}
local lostFlag = {}     -- 버프 이름 -> 제거 이벤트를 받은 시각
local recastAt = {}     -- 버프 이름 -> 내가 그 주문을 마지막으로 쓴 시각

-- 상태 변화 기록 (/ba 로그): 잘못 뜨는 경우 원인 확인용
local function Log(msg)
  if not db then return end
  db.log = db.log or {}
  local t = date and date("%H:%M:%S") or ""
  table.insert(db.log, t .. ((InCombatLockdown and InCombatLockdown()) and " [전투] " or " ") .. msg)
  while #db.log > 40 do table.remove(db.log, 1) end
end

local function Print(msg)
  if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99버프 알림|r " .. msg) end
end

-- 화면 부품 ----------------------------------------------------------------------

local function SetF(fs, size, bold)
  pcall(fs.SetFont, fs, bold and FONT_B or FONT_R, size or 12)
  return fs
end
local function Solid(tex, r, g, b, a)
  if tex.SetColorTexture then tex:SetColorTexture(r, g, b, a or 1)
  else tex:SetTexture("Interface\\Buttons\\WHITE8X8") tex:SetVertexColor(r, g, b, a or 1) end
end
local function Muted(fs, size) SetF(fs, size or 11) fs:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3]) return fs end

local function FlatButton(parent, text, w, primary, fn)
  local b = CreateFrame("Button", nil, parent)
  b:SetWidth(w)
  b:SetHeight(24)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints()
  b.base = primary and C_SEL or C_BTN
  b.hover = primary and C_SEL_HI or C_BTN_HI
  Solid(b.bg, b.base[1], b.base[2], b.base[3], 1)
  -- 1px 테두리 (마우스 올리면 강조색)
  b.edges = {}
  for i, pt in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" }, { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
    local t = b:CreateTexture(nil, "BORDER")
    t:SetPoint(pt[1]); t:SetPoint(pt[2])
    if i <= 2 then t:SetHeight(1) else t:SetWidth(1) end
    Solid(t, C_BTN_EDGE[1], C_BTN_EDGE[2], C_BTN_EDGE[3], 1)
    b.edges[i] = t
  end
  b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.label:SetPoint("CENTER", b, "CENTER", 0, 0)
  SetF(b.label, 12, primary)
  b.label:SetText(text)
  b.label:SetTextColor(primary and 1 or C_TEXT[1], primary and 1 or C_TEXT[2], primary and 1 or C_TEXT[3])
  b:SetScript("OnEnter", function()
    Solid(b.bg, b.hover[1], b.hover[2], b.hover[3], 1)
    for _, t in ipairs(b.edges) do Solid(t, C_ACCENT[1], C_ACCENT[2], C_ACCENT[3], 1) end
  end)
  b:SetScript("OnLeave", function()
    Solid(b.bg, b.base[1], b.base[2], b.base[3], 1)
    for _, t in ipairs(b.edges) do Solid(t, C_BTN_EDGE[1], C_BTN_EDGE[2], C_BTN_EDGE[3], 1) end
  end)
  b:SetScript("OnClick", fn)
  return b
end
local function Recolor(b, base, hover)
  b.base, b.hover = base, hover
  Solid(b.bg, base[1], base[2], base[3], 1)
end

local function IconButton(parent, text, size, color, fn)
  local b = CreateFrame("Button", nil, parent)
  b:SetWidth(20)
  b:SetHeight(20)
  b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  b.label:SetPoint("CENTER", b, "CENTER", 0, 0)
  SetF(b.label, size or 15, true)
  b.label:SetText(text)
  local c = color or C_MUTED
  b.label:SetTextColor(c[1], c[2], c[3])
  b:SetScript("OnEnter", function() b.label:SetTextColor(1, 1, 1) end)
  b:SetScript("OnLeave", function() b.label:SetTextColor(c[1], c[2], c[3]) end)
  b:SetScript("OnClick", fn)
  return b
end

-- 데이터 -------------------------------------------------------------------------

local function CharKey()
  local n = UnitName and UnitName("player") or "?"
  local r = GetRealmName and GetRealmName() or ""
  return n .. "-" .. r
end
local function List()
  db.chars = db.chars or {}
  local k = CharKey()
  db.chars[k] = db.chars[k] or { buffs = {} }
  return db.chars[k].buffs
end

-- i번째 내 버프: 이름, 상태("ok"/"none"/"secret"), 주문번호, 아이콘, 남은 지속, 종료 시각, 인스턴스
local function BuffAt(i)
  local bn, sid, icon, dur, exp, inst
  if C_UnitAuras and C_UnitAuras.GetBuffDataByIndex then
    local d = C_UnitAuras.GetBuffDataByIndex("player", i)
    if not d then return nil, "none" end
    bn, sid, icon, dur, exp, inst = d.name, d.spellId or d.spellID, d.icon, d.duration, d.expirationTime, d.auraInstanceID
  elseif UnitBuff then
    local r = { UnitBuff("player", i) }
    bn, icon, dur, exp, sid = r[1], r[2], r[5], r[6], r[10]
  end
  if not bn then return nil, "none" end
  if issecretvalue then
    if issecretvalue(bn) then return nil, "secret" end
    if sid and issecretvalue(sid) then sid = nil end
    if icon and issecretvalue(icon) then icon = nil end
    if dur and issecretvalue(dur) then dur = nil end
    if exp and issecretvalue(exp) then exp = nil end
  end
  return bn, "ok", sid, icon, dur, exp, inst
end

local function InCombat() return InCombatLockdown and InCombatLockdown() end

-- 지금 걸린 버프 전부 읽기. 전투 중이면 읽을 수 없습니다.
local function ReadAll()
  local out, seen = {}, {}
  for i = 1, 40 do
    local ok, bn, st, sid, icon = pcall(BuffAt, i)
    if not ok or st == "secret" then return nil end
    if st == "none" then break end
    if not seen[bn] then
      seen[bn] = true
      out[#out + 1] = { name = bn, sid = sid, icon = icon }
    end
  end
  return out
end

-- 이름으로 있는지 확인 (true/false/nil=알 수 없음). 전투 중에는 저장해 둔 주문 번호로 확인합니다.
local function HasBuffRaw(e)
  local name = e.name
  if not InCombat() then seenCombat[name], missTicks[name] = nil, 0 end
  local complete = false
  for i = 1, 40 do
    local ok, bn, st, sid, icon, dur, exp, inst = pcall(BuffAt, i)
    if not ok then break end
    if st == "none" then complete = true break end
    if st == "secret" then break end
    if bn == name then
      if sid then e.sid = sid end
      if icon then e.icon = icon end
      if inst then instOf[name] = inst end
      if exp and exp > 0 then expOf[name] = exp end
      missTicks[name] = 0
      return true
    end
  end
  if complete then return false end
  if not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) or not e.sid then return nil end
  local ok, aura = pcall(function() return C_UnitAuras.GetPlayerAuraBySpellID(e.sid) and true or false end)
  if ok and aura then
    seenCombat[name], missTicks[name] = true, 0
    return true
  end
  if seenCombat[name] then
    missTicks[name] = (missTicks[name] or 0) + 1
    if missTicks[name] >= 3 then return false end
  end
  return nil
end
local function HasBuff(e)
  local ok, v = pcall(HasBuffRaw, e)
  if ok and type(v) == "boolean" then return v end
  return nil
end

-- 알림 ---------------------------------------------------------------------------

local function PlayAlert()
  local played = false
  if PlaySoundFile then
    local ok, willPlay = pcall(PlaySoundFile, SOUND_FILE, "Master")
    if ok and willPlay then played = true end
  end
  if not played and PlaySound then
    local ok = false
    if SOUNDKIT and SOUNDKIT.READY_CHECK then ok = pcall(PlaySound, SOUNDKIT.READY_CHECK, "Master") end
    if not ok then pcall(PlaySound, "ReadyCheck") end
  end
end

-- 사망음: 캐릭터가 죽으면 한 번 재생 (기본 켜짐, db.deathSound == false면 끔)
local deathHandle
local function PlayDeathSound()
  if not PlaySoundFile then return false end
  if deathHandle and StopSound then pcall(StopSound, deathHandle) end
  local ok, willPlay, handle = pcall(PlaySoundFile, DEATH_SOUND, "Master")
  deathHandle = ok and handle or nil
  return ok and willPlay and true or false
end
local function StopDeathSound()
  if deathHandle and StopSound then pcall(StopSound, deathHandle) end
  deathHandle = nil
end

local pendingSync = false
local SyncSlots

local function SpellTarget(e)
  -- 버프 이름과 같은 이름의 주문이 있으면 그 이름으로, 없으면 주문 번호로 주문 이름을 찾아 씁니다.
  local known = false
  pcall(function()
    if C_Spell and C_Spell.GetSpellInfo then known = C_Spell.GetSpellInfo(e.name) ~= nil
    elseif GetSpellInfo then known = GetSpellInfo(e.name) ~= nil end
  end)
  if known then return e.name end
  if e.sid then
    local nm
    pcall(function()
      if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(e.sid)
        nm = info and info.name
      elseif GetSpellInfo then
        nm = GetSpellInfo(e.sid)
      end
    end)
    return nm
  end
  return nil
end

local function BuildAlerts()
  local a = CreateFrame("Frame", "BuffAlertIcons", UIParent)
  a:SetWidth(ICON)
  a:SetHeight(ICON + 16)
  a:SetFrameStrata("HIGH")
  a:SetMovable(true)
  a:SetClampedToScreen(true)
  local function DragStart(s) if db.unlocked then a:StartMoving() end end
  local function DragStop()
    a:StopMovingOrSizing()
    local l, t = a:GetLeft(), a:GetTop()
    local ut = UIParent:GetTop()
    if l and t and ut then
      a:ClearAllPoints()
      a:SetPoint("TOPLEFT", UIParent, "TOPLEFT", l, t - ut)
      db.apos = { l, t - ut }
    end
  end
  if db.apos then a:SetPoint("TOPLEFT", UIParent, "TOPLEFT", db.apos[1], db.apos[2])
  else a:SetPoint("CENTER", UIParent, "CENTER", 0, 140) end
  a.icons = {}
  for i = 1, 12 do
    -- 클릭하면 버프를 다시 쓰는 보안 버튼. 전투 중에는 모양을 바꿀 수 없어서
    -- 칸마다 고정해 두고 투명도로만 보였다 안 보였다 합니다.
    local okb, b = pcall(CreateFrame, "Button", "BuffAlertSlot" .. i, a, "SecureActionButtonTemplate")
    if not okb or not b then b = CreateFrame("Button", nil, a) end
    b:SetWidth(ICON)
    b:SetHeight(ICON + 16)
    -- 이 클라이언트는 type="spell" 대신 매크로 버튼만 시전됩니다 (TotemChain과 같은 방식).
    local modern = false
    if GetCVar then
      local okc, v = pcall(GetCVar, "ActionButtonUseKeyDown")
      if okc and v ~= nil then modern = true end
    end
    if modern then pcall(b.RegisterForClicks, b, "AnyDown", "AnyUp")
    else pcall(b.RegisterForClicks, b, "AnyUp") end
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnDragStart", DragStart)
    b:SetScript("OnDragStop", DragStop)
    b.edge = b:CreateTexture(nil, "BACKGROUND")
    b.edge:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
    b.edge:SetWidth(ICON)
    b.edge:SetHeight(ICON)
    Solid(b.edge, C_RED[1], C_RED[2], C_RED[3], 1)
    b.tex = b:CreateTexture(nil, "ARTWORK")
    b.tex:SetPoint("TOPLEFT", b, "TOPLEFT", 2, -2)
    b.tex:SetWidth(ICON - 4)
    b.tex:SetHeight(ICON - 4)
    b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.name:SetPoint("TOP", b.edge, "BOTTOM", 0, -2)
    b.name:SetWidth(ICON + 24)
    SetF(b.name, 11, true)
    b.name:SetTextColor(1, 0.45, 0.4)
    b:SetAlpha(0)
    b:SetScript("OnEnter", function(self)
      self = self or this
      if self.active and self.e then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        GameTooltip:AddLine(self.e.name, 1, 1, 1)
        GameTooltip:AddLine("클릭: 이 버프 사용", 0.8, 0.8, 0.8)
        GameTooltip:Show()
      end
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:Hide()
    a.icons[i] = b
    -- 클릭 차단막: 버프가 걸려 있어 아이콘이 안 보일 때 이 자리를 눌러도 시전되지 않게 막습니다.
    -- 보안 버튼은 전투 중에 속성을 못 바꾸지만, 이 막은 보안 프레임이 아니라서
    -- 전투 중에도 보이기/숨기기가 됩니다. (보안 버튼에 붙이지 않고 a 에 붙임)
    local k = CreateFrame("Frame", nil, a)
    k:SetWidth(ICON)
    k:SetHeight(ICON + 16)
    k:SetFrameLevel(b:GetFrameLevel() + 10)
    k:EnableMouse(true)
    k:Hide()
    b.blocker = k
  end
  -- 위치 이동용 표시 (보안 버튼이 아님)
  local m = CreateFrame("Frame", nil, a)
  m:SetWidth(ICON + 24)
  m:SetHeight(ICON)
  m:SetPoint("TOPLEFT", a, "BOTTOMLEFT", 0, -22)
  m:EnableMouse(true)
  m:RegisterForDrag("LeftButton")
  m:SetScript("OnDragStart", DragStart)
  m:SetScript("OnDragStop", DragStop)
  m.bg = m:CreateTexture(nil, "BACKGROUND")
  m.bg:SetAllPoints()
  Solid(m.bg, C_SEL[1], C_SEL[2], C_SEL[3], 0.9)
  m.t = m:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  m.t:SetPoint("CENTER", m, "CENTER", 0, 0)
  m.t:SetWidth(ICON + 16)
  SetF(m.t, 11, true)
  m.t:SetText("끌어서 이동")
  m:Hide()
  a.mover = m
  local t = 0
  a:SetScript("OnUpdate", function(_, el)
    t = t + (el or 0)
    local al = 0.65 + 0.35 * math.abs(math.sin(t * 3))
    for i = 1, #a.icons do
      local b = a.icons[i]
      if b.active then b:SetAlpha(al) end
    end
  end)
  alerts = a
end

-- 칸 배치와 시전 설정은 전투 밖에서만 바꿀 수 있습니다.
SyncSlots = function()
  if not alerts or not db then return end
  if InCombat() then pendingSync = true return end
  pendingSync = false
  local list = List()
  local n = math.min(#list, #alerts.icons)
  for i = 1, #alerts.icons do
    local b = alerts.icons[i]
    local e = list[i]
    if i <= n and e then
      b:ClearAllPoints()
      b:SetPoint("TOPLEFT", alerts, "TOPLEFT", (i - 1) * (ICON + 8), 0)
      local sp = SpellTarget(e)
      e.castName = sp
      if sp then
        b:SetAttribute("type", "macro")
        b:SetAttribute("macrotext", "/cast " .. sp)
        b:SetAttribute("unit", "player")
      else
        b:SetAttribute("type", nil)
      end
      b.e = e
      b.tex:SetTexture(e.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
      b.name:SetText(e.name)
      b:Show()
      if b.blocker then
        b.blocker:ClearAllPoints()
        b.blocker:SetPoint("TOPLEFT", alerts, "TOPLEFT", (i - 1) * (ICON + 8), 0)
        if b.active then b.blocker:Hide() else b.blocker:Show() end
      end
    else
      b.e = nil
      b.active = false
      b:SetAlpha(0)
      b:Hide()
      if b.blocker then b.blocker:Hide() end
    end
  end
  alerts:SetWidth(math.max(ICON, n * (ICON + 8) - 8))
  alerts:Show()
end

local function ShowAlerts(missing)
  if not alerts then return end
  local miss = {}
  for _, e in ipairs(missing) do miss[e.name] = true end
  local list = List()
  for i = 1, #alerts.icons do
    local b = alerts.icons[i]
    local e = list[i]
    if e and b.e == e then
      if e.icon then b.tex:SetTexture(e.icon) end
      b.active = miss[e.name] and true or false
      if not b.active then b:SetAlpha(0) end
    else
      b.active = false
      b:SetAlpha(0)
    end
    -- 버프가 꺼져 아이콘이 보일 때만 클릭을 통과시키고, 그 외에는 막습니다.
    if b.blocker then
      if b.e and not b.active then b.blocker:Show() else b.blocker:Hide() end
    end
  end
  if db.unlocked then alerts.mover:Show() else alerts.mover:Hide() end
end

local function Evaluate()
  needEval = false
  local list = List()
  local dead = UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")
  if dead then
    for k in pairs(state) do state[k] = nil end
    missingNow = {}
    ShowAlerts({})
    return
  end
  if GetTime() < graceUntil then return end
  local missing, lost = {}, false
  for _, e in ipairs(list) do
    local has = HasBuff(e)
    local raw = has
    local prev = state[e.name]
    if has == nil then
      has = prev
      if has == true and expOf[e.name] and GetTime() >= expOf[e.name] then has = false end
    end
    local lf = lostFlag[e.name]
    if lf then
      local now = GetTime()
      local rc = recastAt[e.name]
      if rc and rc >= lf - 2 then
        -- 다시 쓴 버프가 예전 버프를 밀어낸 것: 사라진 게 아님
        lostFlag[e.name] = nil
        if raw == nil then has = true end
      elseif raw == true then
        lostFlag[e.name] = nil
      elseif now - lf >= 0.6 then
        -- 제거 이벤트 뒤 0.6초 동안 다시 쓴 기록이 없으면 사라진 것으로 봅니다.
        if raw == nil then has = false prev = true end
        lostFlag[e.name] = nil
        Log(e.name .. " 제거 이벤트로 없음 처리")
      end
    end
    if has == false then
      missing[#missing + 1] = e
      if prev == true then lost = true end
    end
    if has ~= prev then Log(e.name .. " " .. tostring(prev) .. " -> " .. tostring(has)) end
    state[e.name] = has
  end
  missingNow = missing
  if #missing > 0 and db.sound ~= false then
    local now = GetTime()
    if db.repeatSound then
      if now - lastSound >= 3 then lastSound = now PlayAlert() end
    elseif lost then
      lastSound = now
      PlayAlert()
    end
  end
  ShowAlerts(missing)
end

-- 설정창 -------------------------------------------------------------------------

local function ApplyBg()
  local f = frame
  if not f then return end
  -- 투명도 0%일 때 상수 스타일 기본 진하기
  local a = 1 - (db.transp or 0) / 100
  Solid(f.bg, C_BG[1], C_BG[2], C_BG[3], BG_ALPHA * a)
  for _, e in ipairs(f.edges) do Solid(e, 0, 0, 0, a) end
  Solid(f.accent, C_ACCENT[1], C_ACCENT[2], C_ACCENT[3], a)
  Solid(f.line, C_BTN_EDGE[1], C_BTN_EDGE[2], C_BTN_EDGE[3], a)
end

local function RefreshUI()
  if not frame or not frame:IsShown() then return end
  local list = List()
  local total = #list
  if offset > total - ROWS then offset = total - ROWS end
  if offset < 0 then offset = 0 end
  frame.head:SetText("관리 중인 버프 " .. total .. "개")
  for i = 1, ROWS do
    local row = frame.rows[i]
    local e = list[offset + i]
    if e then
      row.e = e
      row.icon:SetTexture(e.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
      row.name:SetText(e.name)
      local st = state[e.name]
      if st == true then row.st:SetText("|cff2fa26a있음|r")
      elseif st == false then row.st:SetText("|cffe04a3a없음|r")
      else row.st:SetText("|cffaaaaaa확인 중|r") end
      row:Show()
    else
      row:Hide()
    end
  end
  if total == 0 then frame.empty:Show() else frame.empty:Hide() end
  local ON, ONH = C_SEL, C_SEL_HI
  local OFF, OFFH = C_BTN, C_BTN_HI
  frame.bSound.label:SetText("알림음 " .. (db.sound ~= false and "켜짐" or "꺼짐"))
  if db.sound ~= false then Recolor(frame.bSound, ON, ONH) else Recolor(frame.bSound, OFF, OFFH) end
  frame.bRepeat.label:SetText("반복 " .. (db.repeatSound and "켜짐" or "꺼짐"))
  if db.repeatSound then Recolor(frame.bRepeat, ON, ONH) else Recolor(frame.bRepeat, OFF, OFFH) end
  frame.bDeath.label:SetText("사망음 " .. (db.deathSound ~= false and "켜짐" or "꺼짐"))
  if db.deathSound ~= false then Recolor(frame.bDeath, ON, ONH) else Recolor(frame.bDeath, OFF, OFFH) end
  frame.bMove.label:SetText(db.unlocked and "아이콘 위치 고정" or "아이콘 위치 이동")
  if db.unlocked then Recolor(frame.bMove, C_SEL, C_SEL_HI)
  else Recolor(frame.bMove, C_BTN, C_BTN_HI) end
  frame.tlabel:SetText("투명도 " .. (db.transp or 0) .. "%")
end

local function Reset()
  for k in pairs(state) do state[k] = nil end
  needEval = true
end

local function SetFromCurrent(add)
  if InCombat() then
    Print("전투 중에는 버프를 읽을 수 없습니다. 전투가 끝난 뒤에 눌러주세요.")
    return
  end
  local cur = ReadAll()
  if not cur then Print("버프를 읽지 못했습니다. 잠시 뒤에 다시 눌러주세요.") return end
  local list = List()
  if not add then
    for i = #list, 1, -1 do list[i] = nil end
  end
  local have = {}
  for _, e in ipairs(list) do have[e.name] = true end
  local n = 0
  for _, e in ipairs(cur) do
    if not have[e.name] then list[#list + 1] = e have[e.name] = true n = n + 1 end
  end
  offset = 0
  graceUntil = 0
  Reset()
  SyncSlots()
  if #cur == 0 then Print("걸려 있는 버프가 없습니다. 쓰고 싶은 버프를 건 뒤에 눌러주세요.")
  else Print((add and "추가: " or "설정: ") .. n .. "개 (지금 " .. #list .. "개 관리 중)") end
  RefreshUI()
end

local function ClearAll()
  if InCombat() then Print("전투 중에는 목록을 바꿀 수 없습니다.") return end
  local list = List()
  for i = #list, 1, -1 do list[i] = nil end
  Reset()
  SyncSlots()
  ShowAlerts({})
  RefreshUI()
  Print("관리 목록을 비웠습니다.")
end

local function BuildFrame()
  local f = CreateFrame("Frame", "BuffAlertFrame", UIParent)
  f:SetWidth(340)
  f:SetFrameStrata("MEDIUM")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:EnableMouseWheel(true)
  f:SetClampedToScreen(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(s) s = s or this s:StartMoving() end)
  f:SetScript("OnDragStop", function(s)
    s = s or this
    s:StopMovingOrSizing()
    local l, t = s:GetLeft(), s:GetTop()
    local ut = UIParent:GetTop()
    if l and t and ut then
      s:ClearAllPoints()
      s:SetPoint("TOPLEFT", UIParent, "TOPLEFT", l, t - ut)
      db.pos = { l, t - ut }
    end
  end)
  f:SetScript("OnMouseWheel", function(_, delta)
    offset = offset - (delta or arg1 or 0)
    RefreshUI()
  end)
  if db.pos then f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", db.pos[1], db.pos[2])
  else f:SetPoint("CENTER", UIParent, "CENTER", 0, 0) end

  f.edges = {}
  for _, def in ipairs({ { "TOPLEFT", "TOPRIGHT", "h" }, { "BOTTOMLEFT", "BOTTOMRIGHT", "h" },
    { "TOPLEFT", "BOTTOMLEFT", "w" }, { "TOPRIGHT", "BOTTOMRIGHT", "w" } }) do
    local t = f:CreateTexture(nil, "BORDER")
    t:SetPoint(def[1], f, def[1], 0, 0)
    t:SetPoint(def[2], f, def[2], 0, 0)
    if def[3] == "h" then t:SetHeight(1) else t:SetWidth(1) end
    f.edges[#f.edges + 1] = t
  end
  f.bg = f:CreateTexture(nil, "BORDER")
  f.bg:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
  f.bg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
  f.accent = f:CreateTexture(nil, "ARTWORK")
  f.accent:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
  f.accent:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
  f.accent:SetHeight(3)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", PADX, -12)
  SetF(title, 16, true)
  title:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])
  title:SetText("버프 알림")
  local x = IconButton(f, "X", 15, C_MUTED, function() f:Hide() end)
  x:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -10)

  local desc = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  desc:SetPoint("TOPLEFT", f, "TOPLEFT", PADX, -40)
  desc:SetWidth(CW)
  desc:SetJustifyH("LEFT")
  Muted(desc, 11)
  desc:SetText("관리할 버프를 모두 건 뒤 '현재 버프로 설정'을 누르세요. 그 버프가 사라지면 아이콘과 알림음으로 알려줍니다.")

  f.bSet = FlatButton(f, "현재 버프로 설정", 160, true, function() SetFromCurrent(false) end)
  f.bSet:SetPoint("TOPLEFT", f, "TOPLEFT", PADX, -76)
  f.bAdd = FlatButton(f, "현재 버프 추가", 146, false, function() SetFromCurrent(true) end)
  f.bAdd:SetPoint("LEFT", f.bSet, "RIGHT", 6, 0)

  f.line = f:CreateTexture(nil, "ARTWORK")
  f.line:SetPoint("TOPLEFT", f, "TOPLEFT", PADX, -112)
  f.line:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PADX, -112)
  f.line:SetHeight(1)

  f.head = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.head:SetPoint("TOPLEFT", f, "TOPLEFT", PADX, -122)
  SetF(f.head, 13, true)
  f.head:SetTextColor(C_RED[1], C_RED[2], C_RED[3])

  f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.empty:SetPoint("TOPLEFT", f, "TOPLEFT", PADX, -150)
  f.empty:SetWidth(CW)
  f.empty:SetJustifyH("LEFT")
  Muted(f.empty, 12)
  f.empty:SetText("아직 등록된 버프가 없습니다.")

  f.rows = {}
  for i = 1, ROWS do
    local row = CreateFrame("Frame", nil, f)
    row:SetWidth(CW)
    row:SetHeight(26)
    row:SetPoint("TOPLEFT", f, "TOPLEFT", PADX, -144 - (i - 1) * 28)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    Solid(row.bg, C_PANEL[1], C_PANEL[2], C_PANEL[3], 1)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetWidth(20)
    row.icon:SetHeight(20)
    row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
    row.name:SetWidth(190)
    row.name:SetJustifyH("LEFT")
    SetF(row.name, 12)
    row.name:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])
    pcall(row.name.SetWordWrap, row.name, false)
    row.st = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.st:SetPoint("RIGHT", row, "RIGHT", -30, 0)
    SetF(row.st, 11)
    row.del = IconButton(row, "x", 14, C_RED, function()
      local e = row.e
      if not e then return end
      if InCombat() then Print("전투 중에는 목록을 바꿀 수 없습니다.") return end
      local list = List()
      for k = 1, #list do if list[k] == e then table.remove(list, k) break end end
      state[e.name] = nil
      needEval = true
      SyncSlots()
      RefreshUI()
    end)
    row.del:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row:Hide()
    f.rows[i] = row
  end

  local by = -144 - ROWS * 28 - 8
  f.bSound = FlatButton(f, "알림음 켜짐", 100, false, function()
    db.sound = not (db.sound ~= false)
    RefreshUI()
  end)
  f.bSound:SetPoint("TOPLEFT", f, "TOPLEFT", PADX, by)
  f.bRepeat = FlatButton(f, "반복 꺼짐", 100, false, function()
    db.repeatSound = not db.repeatSound
    RefreshUI()
  end)
  f.bRepeat:SetPoint("LEFT", f.bSound, "RIGHT", 6, 0)
  f.bTest = FlatButton(f, "알림음 듣기", 100, false, PlayAlert)
  f.bTest:SetPoint("LEFT", f.bRepeat, "RIGHT", 6, 0)
  f.bDeath = FlatButton(f, "사망음 켜짐", 154, false, function()
    db.deathSound = not (db.deathSound ~= false)
    if db.deathSound == false then StopDeathSound() end
    RefreshUI()
  end)
  f.bDeath:SetPoint("TOPLEFT", f, "TOPLEFT", PADX, by - 30)
  f.bDeathTest = FlatButton(f, "사망음 듣기", 152, false, function()
    if not PlayDeathSound() then
      Print("사망음을 재생하지 못했습니다. 새 음원 파일은 게임을 완전히 껐다 켜야 인식됩니다.")
    end
  end)
  f.bDeathTest:SetPoint("LEFT", f.bDeath, "RIGHT", 6, 0)
  f.bMove = FlatButton(f, "아이콘 위치 이동", 154, false, function()
    db.unlocked = not db.unlocked
    ShowAlerts(missingNow)
    RefreshUI()
  end)
  f.bMove:SetPoint("TOPLEFT", f, "TOPLEFT", PADX, by - 60)
  f.bClear = FlatButton(f, "목록 비우기", 152, false, ClearAll)
  f.bClear:SetPoint("LEFT", f.bMove, "RIGHT", 6, 0)

  local ty = by - 96
  f.tlabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.tlabel:SetPoint("TOPLEFT", f, "TOPLEFT", PADX, ty)
  Muted(f.tlabel, 11)
  pcall(function()
    local sl = CreateFrame("Slider", nil, f)
    sl:SetOrientation("HORIZONTAL")
    sl:SetWidth(220)
    sl:SetHeight(16)
    sl:SetPoint("TOPLEFT", f, "TOPLEFT", PADX + 86, ty + 4)
    sl:SetMinMaxValues(0, 100)
    sl:SetValueStep(5)
    local tr = sl:CreateTexture(nil, "BACKGROUND")
    tr:SetPoint("LEFT", sl, "LEFT", 0, 0)
    tr:SetPoint("RIGHT", sl, "RIGHT", 0, 0)
    tr:SetHeight(4)
    Solid(tr, C_BTN_EDGE[1], C_BTN_EDGE[2], C_BTN_EDGE[3], 1)
    local th = sl:CreateTexture(nil, "OVERLAY")
    th:SetWidth(8)
    th:SetHeight(16)
    Solid(th, C_ACCENT[1], C_ACCENT[2], C_ACCENT[3], 1)
    sl:SetThumbTexture(th)
    sl:SetValue(db.transp or 0)
    sl:SetScript("OnValueChanged", function(_, v)
      v = v or arg1
      if not v then return end
      db.transp = math.floor(v / 5 + 0.5) * 5
      f.tlabel:SetText("투명도 " .. db.transp .. "%")
      ApplyBg()
    end)
  end)
  f:SetHeight(-ty + 30)
  f:SetScript("OnShow", function() RefreshUI() end)
  f:Hide()
  frame = f
  ApplyBg()
end

-- 미니맵 버튼 --------------------------------------------------------------------

local atan2 = math.atan2 or math.atan
local mm

local function UpdateMinimapPos()
  if not mm then return end
  local angle = math.rad(db.mmAngle or 200)
  local radius = (Minimap:GetWidth() / 2) + 5
  mm:ClearAllPoints()
  mm:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function BuildMinimapButton()
  local b = CreateFrame("Button", "BuffAlertMinimapButton", Minimap)
  b:SetWidth(31)
  b:SetHeight(31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  pcall(b.RegisterForClicks, b, "LeftButtonUp")
  b:RegisterForDrag("LeftButton")
  local icon = b:CreateTexture(nil, "BACKGROUND")
  icon:SetWidth(20)
  icon:SetHeight(20)
  icon:SetTexture("Interface\\Icons\\Spell_Holy_PowerWordShield")
  icon:SetPoint("CENTER", b, "CENTER", 0, 1)
  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetWidth(53)
  border:SetHeight(53)
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  b:SetScript("OnClick", function()
    if frame:IsShown() then frame:Hide() else frame:Show() end
  end)
  b:SetScript("OnDragStart", function(f) f = f or this f.dragging = true GameTooltip:Hide() end)
  b:SetScript("OnDragStop", function(f) f = f or this f.dragging = false end)
  b:SetScript("OnUpdate", function(f)
    f = f or this
    if not f.dragging then return end
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    db.mmAngle = math.deg(atan2(cy / scale - my, cx / scale - mx))
    UpdateMinimapPos()
  end)
  b:SetScript("OnEnter", function(f)
    f = f or this
    GameTooltip:SetOwner(f, "ANCHOR_LEFT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("버프 알림", 1, 1, 1)
    GameTooltip:AddLine("클릭: 설정창 열기/닫기", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("드래그: 아이콘 위치 이동", 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  mm = b
  UpdateMinimapPos()
  if db.mmHide then b:Hide() else b:Show() end
end

-- 시작 ---------------------------------------------------------------------------

local driver = CreateFrame("Frame")
local acc = 0
driver:SetScript("OnUpdate", function(_, el)
  if not db then return end
  acc = acc + (el or arg1 or 0)
  if acc < 0.3 and not needEval then return end
  acc = 0
  pcall(Evaluate)
  if frame and frame:IsShown() then pcall(RefreshUI) end
end)

local function OnAura(info)
  needEval = true
  if type(info) ~= "table" then return end
  -- 새로 걸린 버프 (값을 읽을 수 있을 때만): 같은 버프면 바로 있음 처리
  local added = info.addedAuras
  if type(added) == "table" and not (issecretvalue and issecretvalue(added)) then
    for _, a in ipairs(added) do
      local nm, sid, inst = a.name, a.spellId or a.spellID, a.auraInstanceID
      if not (issecretvalue and ((nm and issecretvalue(nm)) or (sid and issecretvalue(sid)) or (inst and issecretvalue(inst)))) then
        for _, e in ipairs(List()) do
          if (nm and nm == e.name) or (sid and e.sid and sid == e.sid) then
            instOf[e.name] = inst
            lostFlag[e.name] = nil
            recastAt[e.name] = GetTime()
            state[e.name] = true
          end
        end
      end
    end
  end
  local rem = info.removedAuraInstanceIDs
  if rem == nil or (issecretvalue and issecretvalue(rem)) then return end
  for _, id in ipairs(rem) do
    for _, e in ipairs(List()) do
      if instOf[e.name] and instOf[e.name] == id then
        lostFlag[e.name] = GetTime()
        instOf[e.name] = nil
        expOf[e.name] = nil
      end
    end
  end
end

-- 내가 버프 주문을 쓰면 (알림 아이콘 클릭 포함) 전투 중이라도 바로 있음 처리
local function OnCast(spellID)
  if not spellID or (issecretvalue and issecretvalue(spellID)) then return end
  local nm
  pcall(function() nm = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)) or (GetSpellInfo and GetSpellInfo(spellID)) end)
  if not nm or (issecretvalue and issecretvalue(nm)) then return end
  for _, e in ipairs(List()) do
    if nm == e.name or nm == e.castName then
      recastAt[e.name] = GetTime()
      lostFlag[e.name] = nil
      expOf[e.name] = nil
      if state[e.name] ~= true then Log(e.name .. " 다시 씀 -> 있음") end
      state[e.name] = true
      needEval = true
    end
  end
end

driver:RegisterEvent("PLAYER_LOGIN")
driver:RegisterEvent("PLAYER_DEAD")
pcall(driver.RegisterUnitEvent, driver, "UNIT_SPELLCAST_SUCCEEDED", "player")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("PLAYER_REGEN_ENABLED")
pcall(driver.RegisterUnitEvent, driver, "UNIT_AURA", "player")
driver:SetScript("OnEvent", function(_, event, a1, a2, ...)
  if event == "PLAYER_LOGIN" then
    BuffAlertDB = BuffAlertDB or {}
    db = BuffAlertDB
    BuildAlerts()
    BuildFrame()
    BuildMinimapButton()
    SyncSlots()
    graceUntil = GetTime() + 4
    Print("로드됨. /ba 로 설정창을 엽니다.")
  elseif event == "PLAYER_ENTERING_WORLD" then
    graceUntil = GetTime() + 4
  elseif event == "PLAYER_REGEN_ENABLED" and db then
    if pendingSync then SyncSlots() end
  elseif event == "UNIT_AURA" and db then
    pcall(OnAura, a2)
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" and db then
    local sid = ...
    pcall(OnCast, sid)
  elseif event == "PLAYER_DEAD" and db then
    if db.deathSound ~= false then PlayDeathSound() end
  end
end)

SLASH_BUFFALERT1 = "/ba"
SLASH_BUFFALERT2 = "/buffalert"
SLASH_BUFFALERT3 = "/버프"
SlashCmdList["BUFFALERT"] = function(msg)
  if not db then return end
  msg = (msg or ""):lower()
  if msg == "set" then SetFromCurrent(false)
  elseif msg == "add" then SetFromCurrent(true)
  elseif msg == "clear" then ClearAll()
  elseif msg == "test" then PlayAlert()
  elseif msg == "debug" then
    Print("관리 " .. #List() .. "개 / 알림음 " .. tostring(db.sound ~= false) .. " / 반복 " .. tostring(db.repeatSound and true or false) .. " / 전투 " .. tostring(InCombat() and true or false))
    for _, e in ipairs(List()) do
      Print(e.name .. " 상태=" .. tostring(state[e.name]) .. " 주문번호=" .. tostring(e.sid) .. " 시전=" .. tostring(SpellTarget(e)))
    end
  elseif msg == "log" or msg == "로그" then
    Print("최근 상태 변화 (최대 40줄):")
    for _, l in ipairs(db.log or {}) do Print("  " .. l) end
  elseif msg == "사망음" or msg == "death" then
    db.deathSound = not (db.deathSound ~= false)
    RefreshUI()
    Print(db.deathSound and "사망음을 켰습니다. 캐릭터가 죽으면 한 번 재생합니다. (들어 보기: /ba 사망음 테스트)" or "사망음을 껐습니다.")
  elseif msg == "사망음 테스트" or msg == "death test" then
    if not PlayDeathSound() then
      Print("사망음을 재생하지 못했습니다. 새 음원 파일은 게임을 완전히 껐다 켜야 인식됩니다.")
    end
  elseif msg == "사망음 정지" or msg == "death stop" then
    StopDeathSound()
  elseif msg == "minimap" then
    db.mmHide = not db.mmHide
    if db.mmHide then mm:Hide() else mm:Show() end
    Print(db.mmHide and "미니맵 아이콘을 숨겼습니다." or "미니맵 아이콘을 표시합니다.")
  else
    if frame:IsShown() then frame:Hide() else frame:Show() end
  end
end
