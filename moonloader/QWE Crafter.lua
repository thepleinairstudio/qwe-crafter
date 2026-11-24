-- QWE Crafter — загрузчик (открытая часть).
-- Здесь НЕТ логики верстака. Весь код скрипта лежит в qwe_crafter_core.dat
-- (урезанный байткод LuaJIT), поэтому игроки не могут его прочитать или изменить.
--
--  * DEV-сборка (ПК автора): если рядом лежит исходник "qwe_crafter_core.src",
--    загрузчик при каждом запуске компилирует его в урезанный байткод
--    "qwe_crafter_core.dat" и запускает ядро. Обновление в dev не ставится,
--    но проверка версии работает (видно, есть ли на GitHub новее).
--  * RELEASE-сборка (игроки): поставляется только "qwe_crafter_core.dat".
--    Загрузчик загружает его и сам обновляет ядро с GitHub (version.json -> .dat).
--
-- Ядро общается с загрузчиком через глобальную таблицу _G.QWE_CRAFTER_UPD.

local REPO_RAW = 'https://raw.githubusercontent.com/thepleinairstudio/qwe-crafter/main/'

local dir  = getWorkingDirectory()
local SRC  = dir .. '\\qwe_crafter_core.src'
local DAT  = dir .. '\\qwe_crafter_core.dat'
local TMPJ = dir .. '\\qwe_crafter_update.json'
local TMPD = dir .. '\\qwe_crafter_core.dat.new'

local dlstatus = require('moonloader').download_status

local function readFile(p) local f = io.open(p, 'rb'); if not f then return nil end local s = f:read('*a'); f:close(); return s end
local function writeFile(p, d) local f = io.open(p, 'wb'); if not f then return false end f:write(d); f:close(); return true end
local function exists(p) local f = io.open(p, 'rb'); if f then f:close(); return true end return false end
local function verNum(v)
	local a, b, c = tostring(v or ''):match('(%d+)%.?(%d*)%.?(%d*)')
	return (tonumber(a) or 0) * 1000000 + (tonumber(b) or 0) * 1000 + (tonumber(c) or 0)
end

-- Общий интерфейс для ядра. Ядро читает .code/.ver и вызывает .check().
-- .code — короткий код состояния, ядро превращает его в свой текст.
local UPD = { busy = false, code = nil, ver = nil, dev = false }
_G.QWE_CRAFTER_UPD = UPD
local function setStatus(code, ver) UPD.code, UPD.ver = code, ver end

function UPD.check(manual, curVer)
	if UPD.busy and os.clock() - (UPD.at or 0) < 30 then return end
	UPD.busy, UPD.at = true, os.clock()
	setStatus('checking', curVer)
	downloadUrlToFile(REPO_RAW .. 'version.json?t=' .. os.time(), TMPJ, function(_, status)
		if status ~= dlstatus.STATUS_ENDDOWNLOADDATA then return end
		local s = readFile(TMPJ); os.remove(TMPJ)
		if not s or not s:find('{', 1, true) then UPD.busy = false; setStatus('neterr', curVer); return end
		local ok, j = pcall(decodeJson, s)
		if not ok or type(j) ~= 'table' or not j.version then
			UPD.busy = false; setStatus('neterr', curVer); return
		end
		UPD.latest = j.version
		if verNum(j.version) <= verNum(curVer) then
			UPD.busy = false; setStatus('uptodate', curVer); return
		end
		-- у автора (dev) новое ядро не ставим — только сообщаем
		if UPD.dev then UPD.busy = false; setStatus('devnewer', j.version); return end
		setStatus('updating', j.version)
		local coreName = j.core or 'moonloader/qwe_crafter_core.dat'
		-- второе скачивание нельзя запускать прямо из колбэка первого: moonloader падает
		-- с «device or resource busy». Запускаем из отдельного потока.
		lua_thread.create(function()
			wait(200)
			downloadUrlToFile(REPO_RAW .. coreName .. '?t=' .. os.time(), TMPD, function(_, st2)
				if st2 ~= dlstatus.STATUS_ENDDOWNLOADDATA then return end
				local bc = readFile(TMPD)
				-- проверка: достаточно большой и грузится как валидный чанк
				local good = bc and #bc > 40000 and loadfile(TMPD) ~= nil
				if not good then
					os.remove(TMPD); UPD.busy = false; setStatus('baddata', j.version); return
				end
				if exists(DAT) then writeFile(DAT .. '.bak', readFile(DAT) or '') end
				local okw = writeFile(DAT, bc)
				os.remove(TMPD)
				if not okw then UPD.busy = false; setStatus('writeerr', j.version); return end
				setStatus('updated', j.version); UPD.busy = false
				lua_thread.create(function() wait(100); thisScript():reload() end)
			end)
		end)
	end)
end

-- ============== ресурсы: иконки и названия докачиваются с GitHub ==============
-- В архиве может не быть папки resource\qwe_crafter (форумы не пускают большие архивы).
-- При первом запуске загрузчик сам скачивает недостающие иконки и names.txt.
-- Когда всё на месте, пишет метку icons.ok и больше сеть не трогает.
local RES   = dir .. '\\resource\\qwe_crafter'
local ICONS = RES .. '\\icons'
local OKF   = RES .. '\\icons.ok'
UPD.icons = { state = 'idle', done = 0, total = 0, failed = 0, gen = 0 }

local function isPng(p)
	local s = readFile(p)
	return s and #s > 60 and s:sub(1, 8) == '\137PNG\r\n\26\n'
end

-- Начать загрузку. Колбэк только ставит флаг (новую загрузку из колбэка запускать нельзя).
-- 404 у Windows приходит как STATUSEX_ENDDOWNLOAD без STATUS_ENDDOWNLOADDATA.
local function start(url, path)
	local job = { done = false, at = os.clock() }
	downloadUrlToFile(url, path, function(_, st)
		if st == dlstatus.STATUS_ENDDOWNLOADDATA or st == dlstatus.STATUSEX_ENDDOWNLOAD then job.done = true end
	end)
	return job
end
-- скачать и дождаться (только внутри потока); вернёт текст файла или nil
local function get(url, path, timeout)
	local job = start(url, path)
	while not job.done and os.clock() - job.at < (timeout or 20) do wait(100) end
	wait(100)
	local s = readFile(path); os.remove(path)
	return job.done and s or nil
end

-- список id: icons.txt в репо, запасной путь — дерево репо через API GitHub
local function fetchList()
	local tmp = RES .. '\\icons.list.tmp'
	local s = get(REPO_RAW .. 'moonloader/resource/qwe_crafter/icons.txt?t=' .. os.time(), tmp) or ''
	local ids = {}
	for line in s:gmatch('[^\r\n]+') do
		if line:match('^%d+$') then ids[#ids + 1] = line else ids = {}; break end
	end
	if #ids >= 10 then return ids end
	local s2 = get('https://api.github.com/repos/thepleinairstudio/qwe-crafter/git/trees/main?recursive=1', tmp, 30) or ''
	ids = {}
	for id in s2:gmatch('moonloader/resource/qwe_crafter/icons/(%d+)%.png') do ids[#ids + 1] = id end
	return ids
end

local function iconsFetch(manual)
	if not manual then
		if exists(OKF) then return end
		wait(2000)
	end
	if not doesDirectoryExist(ICONS) then createDirectory(ICONS) end
	local I = UPD.icons
	I.state, I.manual = 'list', manual and true or nil
	local ids = fetchList()
	if #ids == 0 then I.state = 'neterr'; print('[QWE Crafter loader] icons: no list (network?)'); return end

	-- названия предметов (для тех, у кого нет QWE Trader)
	local NAMES = RES .. '\\names.txt'
	if not exists(NAMES) then
		local s = get(REPO_RAW .. 'moonloader/resource/qwe_crafter/names.txt?t=' .. os.time(), NAMES .. '.tmp')
		if s and s:find('%d+=') and not s:find('<html') then writeFile(NAMES, s); I.gen = I.gen + 1 end
	end

	local need = {}
	for _, id in ipairs(ids) do
		if not isPng(ICONS .. '\\' .. id .. '.png') then need[#need + 1] = id end
	end
	I.total, I.done, I.failed = #need, 0, 0
	if #need == 0 then writeFile(OKF, tostring(#ids)); I.state = 'ok'; return end
	print(('[QWE Crafter loader] downloading %d icons...'):format(#need))
	I.state = 'loading'

	-- по 8 файлов одновременно; файл сначала во .tmp, потом проверка PNG
	local jobs, pos, tries, lastGen = {}, 1, {}, os.clock()
	while pos <= #need or #jobs > 0 do
		while #jobs < 8 and pos <= #need do
			local id = need[pos]; pos = pos + 1
			tries[id] = (tries[id] or 0) + 1
			local dst = ICONS .. '\\' .. id .. '.png'
			local j = start(REPO_RAW .. 'moonloader/resource/qwe_crafter/icons/' .. id .. '.png', dst .. '.tmp')
			j.id, j.dst = id, dst
			jobs[#jobs + 1] = j
		end
		wait(50)
		for k = #jobs, 1, -1 do
			local j = jobs[k]
			local late = os.clock() - j.at > 20
			if j.done or late then
				table.remove(jobs, k)
				local tmp = j.dst .. '.tmp'
				if j.done and isPng(tmp) then
					os.remove(j.dst); os.rename(tmp, j.dst)
					I.done = I.done + 1
				else
					os.remove(tmp)
					if tries[j.id] < 3 then need[#need + 1] = j.id else I.failed = I.failed + 1 end
				end
			end
		end
		-- ядро перечитывает иконки примерно раз в секунду
		if os.clock() - lastGen > 1 then I.gen = I.gen + 1; lastGen = os.clock() end
	end
	I.gen = I.gen + 1
	if I.failed == 0 then
		writeFile(OKF, tostring(#ids)); I.state = 'ok'
	else
		I.state = 'partial' -- при следующем запуске докачает остаток
	end
	print(('[QWE Crafter loader] icons: %d ok, %d failed'):format(I.done, I.failed))
end

-- кнопка «Скачать иконки» в настройках ядра: проверить все иконки заново и докачать недостающие/битые
-- (вызывать из потока, не из колбэка загрузки)
function UPD.iconsStart()
	local s = UPD.icons.state
	if s == 'list' or s == 'loading' then return false end
	os.remove(OKF)
	UPD.icons.state = 'list'
	lua_thread.create(iconsFetch, true)
	return true
end

-- ============================ запуск ============================
local chunk, srcChunk

-- DEV: есть исходник — компилируем его в урезанный байткод и перезаписываем .dat
local code = readFile(SRC)
if code then
	local c, err = loadstring(code, '@qwe_crafter_core')
	if not c then print('[QWE Crafter loader] source compile error: ' .. tostring(err)); return end
	srcChunk = c
	local ok, bc = pcall(string.dump, c, true) -- true = убрать отладочную информацию
	if ok and type(bc) == 'string' and #bc > 0 then
		writeFile(DAT, bc)
	else
		print('[QWE Crafter loader] string.dump failed, running from source')
	end
	UPD.dev = true
end

local c, err = loadfile(DAT)
if c then
	chunk = c
elseif srcChunk then
	print('[QWE Crafter loader] bytecode did not load (' .. tostring(err) .. '), running from source')
	chunk = srcChunk
else
	-- Нет ни исходника, ни ядра (поставили только загрузчик): один раз скачиваем ядро с GitHub.
	print('[QWE Crafter loader] core not found, downloading from GitHub...')
	UPD.busy = true; setStatus('updating')
	function main()
		wait(3000)
		downloadUrlToFile(REPO_RAW .. 'moonloader/qwe_crafter_core.dat?t=' .. os.time(), DAT, function(_, st)
			if st == dlstatus.STATUS_ENDDOWNLOADDATA then
				UPD.busy = false
				thisScript():reload()
			end
		end)
		while true do wait(1000) end
	end
	return
end

chunk()

-- запускаем докачку ресурсов рядом с main() ядра
local coreMain = main
function main()
	lua_thread.create(iconsFetch)
	if coreMain then return coreMain() end
	while true do wait(1000) end
end
