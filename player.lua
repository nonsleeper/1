-- Настенный плеер для CC:Tweaked.
-- Экран: advanced monitor 3 блока в ширину и 4 в высоту.
-- Колонки слева и справа от экрана, все три устройства в одной проводной сети.
-- Треки: https://github.com/nonsleeper/1
--
-- На мониторе: тап по треку, по полосе (перемотка), кнопки |< -10 || +10 >| и ШАФЛ.
-- С компьютера: пробел пауза, стрелки влево/вправо перемотка на 10 с, n/p треки, s шафл, q выход.

local API = "https://api.github.com/repos/nonsleeper/1/git/trees/master?recursive=1"
-- Полный файл с raw.githubusercontent.com с игрового сервера не дочитывается:
-- заголовки приходят (видно длительность), тело зависает. Короткие Range-запросы
-- к тому же адресу возвращают ровно запрошенные байты. Range у jsDelivr для этих
-- файлов отдаёт другие байты, поэтому для звука он не используется.
local MIRRORS = {
    "https://raw.githubusercontent.com/nonsleeper/1/master/",
}
local CACHE = ".player_tracks"
local CHUNK = 4 * 1024
local PIECE = 8 * 1024
local BYTES_PER_SECOND = 6000

local dfpwm = require("cc.audio.dfpwm")

local tracks = {}
local speakers = {}
local order = {}
local orderPos = 1
local selected = 1
local scroll = 1
local playingPath = nil
local session = 0
local volume = 1
local shuffle = false
local paused = false
local status = "Загрузка списка..."
local quit = false
local responseHandle = nil
local position = 0
local totalBytes = 0
local screen = term
local hits = {}

local function paint(bg, fg)
    if bg then screen.setBackgroundColour(bg) end
    if fg then screen.setTextColour(fg) end
end

local function encodePath(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
        parts[#parts + 1] = (part:gsub("[^%w%-_%.~]", function(char)
            return string.format("%%%02X", char:byte())
        end))
    end
    return table.concat(parts, "/")
end

local function titleOf(path)
    return (path:gsub("%.dfpwm$", ""):gsub("%.DFPWM$", ""))
end

local function formatTime(bytes)
    local seconds = math.max(0, math.floor(bytes / BYTES_PER_SECOND))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function headerValue(headers, name)
    if type(headers) ~= "table" then return nil end
    local want = name:lower()
    for key, value in pairs(headers) do
        if tostring(key):lower() == want then return value end
    end
end

local function saveCache()
    local handle = fs.open(CACHE, "w")
    if not handle then return end
    for _, path in ipairs(tracks) do
        handle.writeLine(path)
    end
    handle.close()
end

local function loadCache()
    if not fs.exists(CACHE) then return false end
    local handle = fs.open(CACHE, "r")
    if not handle then return false end
    tracks = {}
    while true do
        local line = handle.readLine()
        if not line then break end
        if line ~= "" then tracks[#tracks + 1] = line end
    end
    handle.close()
    return #tracks > 0
end

local function fetchTracks()
    local response, err = http.get(API, {
        ["User-Agent"] = "CC-Jukebox",
        Accept = "application/json",
    })
    if not response then return nil, tostring(err) end
    local body = response.readAll()
    response.close()
    local data = textutils.unserializeJSON(body)
    if type(data) ~= "table" or type(data.tree) ~= "table" then
        return nil, "GitHub вернул не список"
    end
    local list = {}
    for _, item in ipairs(data.tree) do
        if item.type == "blob" and type(item.path) == "string" and item.path:lower():sub(-6) == ".dfpwm" then
            list[#list + 1] = item.path
        end
    end
    table.sort(list, function(a, b) return a:lower() < b:lower() end)
    if #list == 0 then return nil, "В репозитории нет .dfpwm" end
    return list
end

local function trackIndex(path)
    for i, name in ipairs(tracks) do
        if name == path then return i end
    end
end

local function rebuildOrder()
    order = {}
    for i = 1, #tracks do order[i] = i end
    if shuffle then
        for i = #order, 2, -1 do
            local j = math.random(1, i)
            order[i], order[j] = order[j], order[i]
        end
    end
    orderPos = 1
    local current = trackIndex(playingPath)
    if current then
        for i, value in ipairs(order) do
            if value == current then
                orderPos = i
                break
            end
        end
    end
end

local function stepOrder(delta)
    if #tracks == 0 then return nil end
    if #order ~= #tracks then rebuildOrder() end
    if shuffle and delta > 0 and orderPos >= #order then
        local current = trackIndex(playingPath)
        rebuildOrder()
        if current and #order > 1 and order[1] == current then
            local swap = math.random(2, #order)
            order[1], order[swap] = order[swap], order[1]
        end
        orderPos = 1
        return order[1]
    end
    orderPos = orderPos + delta
    if orderPos < 1 then orderPos = #order end
    if orderPos > #order then orderPos = 1 end
    return order[orderPos]
end

local function refreshSpeakers()
    speakers = {}
    local found = { peripheral.find("speaker") }
    for _, dev in ipairs(found) do
        speakers[#speakers + 1] = { name = peripheral.getName(dev), dev = dev }
    end
end

local function stopSpeakers()
    for _, speaker in ipairs(speakers) do
        pcall(speaker.dev.stop, speaker.dev)
    end
end

local function closeStream()
    local handle = responseHandle
    responseHandle = nil
    if handle then pcall(handle.close, handle) end
end

local function wake()
    os.queueEvent("player_cmd")
end

local function restartStream()
    session = session + 1
    closeStream()
    stopSpeakers()
    wake()
end

local function playIndex(index, offset)
    if not tracks[index] then return end
    offset = math.max(0, math.floor(offset or 0))
    if tracks[index] ~= playingPath then totalBytes = 0 end
    selected = index
    playingPath = tracks[index]
    for i, value in ipairs(order) do
        if value == index then
            orderPos = i
            break
        end
    end
    position = offset
    paused = false
    status = "Start"
    restartStream()
end

local function togglePause()
    if not playingPath then
        if tracks[selected] then playIndex(selected, 0) end
        return
    end
    if paused then
        paused = false
        status = "Playing"
        wake()
    else
        paused = true
        status = "Pause"
        session = session + 1
        closeStream()
        stopSpeakers()
        wake()
    end
end

local function seekTo(bytes)
    if not playingPath then return end
    bytes = math.max(0, math.floor(bytes))
    if totalBytes > 0 then bytes = math.min(bytes, math.max(0, totalBytes - 1)) end
    position = bytes
    status = "Seek"
    if paused then return end
    restartStream()
end

local function seekBy(seconds)
    local dest = position + seconds * BYTES_PER_SECOND
    if totalBytes > 0 and dest >= totalBytes then
        local nextIndex = stepOrder(1)
        if nextIndex then playIndex(nextIndex, 0) end
        return
    end
    seekTo(dest)
end

local function playRelative(delta)
    if #tracks == 0 then return end
    if delta < 0 and playingPath and position > 3 * BYTES_PER_SECOND then
        seekTo(0)
        return
    end
    local index = stepOrder(delta)
    if index then playIndex(index, 0) end
end

local function toggleShuffle()
    shuffle = not shuffle
    rebuildOrder()
    status = shuffle and "Shuffle on" or "Shuffle off"
end

local function changeVolume(delta)
    volume = math.min(3, math.max(0.1, volume + delta))
    volume = math.floor(volume * 10 + 0.5) / 10
end

local function findDisplay()
    local best, bestArea, bestName = nil, 0, nil
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            local monitor = peripheral.wrap(name)
            local width, height = monitor.getSize()
            if width * height > bestArea then
                best, bestArea, bestName = monitor, width * height, name
            end
        end
    end
    return best, bestName
end

local function prepareScreen()
    local monitor, name = findDisplay()
    if not monitor then
        screen = term
        return false, nil
    end
    screen = monitor
    pcall(function() screen.setTextScale(1) end)
    local width, height = screen.getSize()
    if width < 20 or height < 10 then
        pcall(function() screen.setTextScale(0.5) end)
    end
    pcall(function() screen.setCursorBlink(false) end)
    return true, name
end

local function waitForBuffer(my)
    local timer = os.startTimer(2)
    while session == my do
        local event, id = os.pullEvent()
        if event == "speaker_audio_empty" or event == "player_cmd" or (event == "timer" and id == timer) then
            return session == my
        end
    end
    return false
end

local function pushAudio(pcm, my)
    if type(pcm) ~= "table" or #pcm == 0 then return false, "Empty audio" end
    refreshSpeakers()
    if #speakers == 0 then return false, "No speakers" end
    local pending = {}
    for i, speaker in ipairs(speakers) do pending[i] = speaker end
    local tries = 0
    while #pending > 0 and session == my do
        local left = {}
        for _, speaker in ipairs(pending) do
            if type(speaker.dev.playAudio) ~= "function" then
                return false, "No playAudio"
            end
            local ok, accepted = pcall(speaker.dev.playAudio, speaker.dev, pcm, volume)
            if not ok then
                return false, tostring(accepted)
            elseif not accepted then
                left[#left + 1] = speaker
            end
        end
        pending = left
        if #pending > 0 and session == my then
            tries = tries + 1
            if tries > 6 then return false, "Speaker busy" end
            if not waitForBuffer(my) then return false end
            refreshSpeakers()
            local alive, names = {}, {}
            for _, speaker in ipairs(speakers) do names[speaker.name] = true end
            for _, speaker in ipairs(pending) do
                if names[speaker.name] then alive[#alive + 1] = speaker end
            end
            pending = alive
            if #pending == 0 then return false, "Speaker detached" end
        end
    end
    return session == my
end

local requestSerial = 0

local function readPiece(base, encoded, startByte, endByte, my)
    requestSerial = requestSerial + 1
    local url = string.format("%s%s?b=%d&n=%d", base, encoded, startByte, requestSerial)
    local headers = {
        ["User-Agent"] = "CC-Jukebox",
        ["Accept-Encoding"] = "identity",
        ["Range"] = string.format("bytes=%d-%d", startByte, endByte),
    }
    local ok, err = http.request(url, nil, headers, true)
    if not ok then return nil, tostring(err) end
    local timer = os.startTimer(12)
    local response
    while session == my and not response do
        local event, a, b = os.pullEvent()
        if event == "http_success" then
            if a == url then
                response = b
            elseif b and b.close then
                pcall(b.close, b)
            end
        elseif event == "http_failure" and a == url then
            return nil, tostring(b)
        elseif event == "timer" and a == timer then
            return nil, "Timeout"
        end
    end
    if session ~= my then
        if response then pcall(response.close, response) end
        return nil, "Stopped"
    end

    local code = 0
    pcall(function() code = response.getResponseCode() end)
    local responseHeaders = {}
    pcall(function() responseHeaders = response.getResponseHeaders() end)
    local range = headerValue(responseHeaders, "Content-Range")
    local total = range and tonumber(range:match("/(%d+)")) or nil
    if code ~= 206 then
        pcall(response.close, response)
        return nil, "No range " .. tostring(code), total
    end
    local data = response.readAll()
    pcall(response.close, response)
    if not data or #data == 0 then return nil, "Empty piece", total end
    return data, nil, total
end

local function playSlices(decoder, data, my)
    local i = 1
    while i <= #data and session == my do
        local slice = data:sub(i, i + CHUNK - 1)
        i = i + #slice
        local pcm = decoder(slice)
        position = position + #slice
        os.queueEvent("player_draw")
        local pushed, reason = pushAudio(pcm, my)
        if not pushed then return false, reason end
        os.queueEvent("player_draw")
    end
    return session == my
end

local function playFile(path, my, offset)
    refreshSpeakers()
    if #speakers == 0 then
        return false, "No speakers"
    end

    local encoded = encodePath(path)
    local cursor = offset
    local decoder = dfpwm.make_decoder()
    position = offset
    local lastErr = "Download failed"

    while session == my do
        if totalBytes > 0 and cursor >= totalBytes then break end
        local last = cursor + PIECE - 1
        if totalBytes > 0 and last >= totalBytes then last = totalBytes - 1 end
        if totalBytes > 0 then
            status = string.format("Get %d%%", math.floor(cursor / totalBytes * 100))
        else
            status = "Get..."
        end
        os.queueEvent("player_draw")

        local data, err, total
        for _, base in ipairs(MIRRORS) do
            if session ~= my then break end
            data, err, total = readPiece(base, encoded, cursor, last, my)
            if data then break end
            lastErr = err or lastErr
        end
        if session ~= my then return false end
        if total and total > 0 then totalBytes = total end
        if not data then return false, lastErr end

        local expect = last - cursor + 1
        if #data > expect then data = data:sub(1, expect) end
        status = "Playing"
        local played, reason = playSlices(decoder, data, my)
        if not played then
            if session ~= my then return false end
            return false, reason
        end
        local short = #data < expect
        cursor = cursor + #data
        if short then break end
    end

    if session ~= my then return false end
    return true
end

local function audioLoop()
    while not quit do
        if not playingPath or paused then
            os.pullEvent("player_cmd")
        else
            local path = playingPath
            local my = session
            local offset = position
            local ok, err = playFile(path, my, offset)
            if quit then break end
            if session == my then
                if not ok then
                    playingPath = nil
                    paused = true
                    status = tostring(err or "Playback error")
                    os.queueEvent("player_draw")
                else
                    position = 0
                    local nextIndex = stepOrder(1)
                    if nextIndex then
                        playIndex(nextIndex, 0)
                    else
                        playingPath = nil
                        paused = true
                        stopSpeakers()
                        status = "End"
                        os.queueEvent("player_draw")
                    end
                end
            end
        end
    end
end

local function addHit(x, y, w, h, id)
    hits[#hits + 1] = { x = x, y = y, w = w, h = h, id = id }
end

local function hitAt(x, y)
    for i = #hits, 1, -1 do
        local hit = hits[i]
        if x >= hit.x and x < hit.x + hit.w and y >= hit.y and y < hit.y + hit.h then
            return hit.id
        end
    end
end

local function fill(y, bg)
    paint(bg, colours.white)
    screen.setCursorPos(1, y)
    screen.clearLine()
end

local function put(x, y, text, bg, fg)
    paint(bg, fg)
    screen.setCursorPos(x, y)
    screen.write(text)
end

local function button(x, y, w, h, label, bg, fg, id)
    label = label:sub(1, w)
    local pad = w - #label
    local left = math.floor(pad / 2)
    local text = string.rep(" ", left) .. label .. string.rep(" ", pad - left)
    for row = 0, h - 1 do
        put(x, y + row, row == math.floor((h - 1) / 2) and text or string.rep(" ", w), bg, fg)
    end
    addHit(x, y, w, h, id)
end

local function drawBar(y, width)
    local inner = width - 2
    local frac = 0
    if totalBytes > 0 then frac = math.max(0, math.min(1, position / totalBytes)) end
    local filled = math.floor(frac * inner + 0.5)
    local body = string.rep("=", math.max(0, filled - 1))
    if filled > 0 then body = body .. ">" end
    body = body .. string.rep("-", math.max(0, inner - filled))
    local text = " " .. body .. " "
    local fg = "f" .. string.rep("5", math.max(0, filled)) .. string.rep("7", math.max(0, inner - filled)) .. "f"
    local bg = string.rep("f", #text)
    if #fg < #text then fg = fg .. string.rep("f", #text - #fg) end
    paint(colours.black, colours.white)
    screen.setCursorPos(1, y)
    screen.blit(text:sub(1, width), fg:sub(1, width), bg:sub(1, width))
    addHit(1, y, width, 1, "seek")
end

local function draw()
    local width, height = screen.getSize()
    hits = {}
    local tall = height >= 20 and width >= 26
    paint(colours.black, colours.white)
    screen.clear()

    fill(1, colours.gray)
    put(2, 1, "PLAYER", colours.gray, colours.white)
    local volLabel = string.format("- %d%% +", math.floor(volume * 100 + 0.5))
    local volX = width - #volLabel + 1
    put(volX, 1, volLabel, colours.gray, colours.white)
    addHit(volX, 1, 1, 1, "voldown")
    addHit(volX + #volLabel - 1, 1, 1, 1, "volup")

    local title = playingPath and titleOf(playingPath) or "pick a track"
    local timeText = formatTime(position) .. " / " .. (totalBytes > 0 and formatTime(totalBytes) or "-:--")
    local listTop
    local buttonY
    local buttonH = 1

    if tall then
        fill(3, colours.black)
        put(2, 3, "now", colours.black, colours.lightGray)
        fill(4, colours.black)
        put(2, 4, title:sub(1, width - 2), colours.black, colours.lime)
        fill(5, colours.black)
        put(2, 5, timeText, colours.black, colours.white)
        if shuffle then put(width - 3, 5, "MIX", colours.black, colours.orange) end
        drawBar(6, width)
        buttonY = 8
        buttonH = 2
        listTop = 11
    else
        fill(2, colours.black)
        put(1, 2, title:sub(1, math.max(1, width - #timeText - 1)), colours.black, colours.lime)
        put(width - #timeText + 1, 2, timeText, colours.black, colours.white)
        drawBar(3, width)
        buttonY = 4
        listTop = 6
    end

    local labels = {
        { id = "prev", text = "|<" },
        { id = "back", text = "-10" },
        { id = "play", text = (playingPath and not paused) and "||" or ">" },
        { id = "fwd", text = "+10" },
        { id = "next", text = ">|" },
    }
    local count = #labels
    local gap = 1
    if count * 3 + (count - 1) * gap > width then gap = 0 end
    local each = math.floor((width - gap * (count - 1)) / count)
    if each < 1 then each = 1 end
    local totalW = each * count + gap * (count - 1)
    local x = math.floor((width - totalW) / 2) + 1
    if x < 1 then x = 1 end
    for _, item in ipairs(labels) do
        local bg, fg = colours.gray, colours.white
        if item.id == "play" then
            bg = (playingPath and not paused) and colours.lime or colours.orange
            fg = colours.black
        end
        button(x, buttonY, each, buttonH, item.text, bg, fg, item.id)
        x = x + each + gap
    end

    local shuffleY = buttonY + buttonH
    fill(shuffleY, colours.black)
    button(2, shuffleY, 6, 1, "SHUF", shuffle and colours.orange or colours.gray, shuffle and colours.black or colours.white, "shuffle")
    local speakerText = #speakers > 0 and ("spk " .. #speakers) or "no spk"
    put(math.max(9, width - #speakerText + 1), shuffleY, speakerText, colours.black, #speakers > 0 and colours.lightGray or colours.red)

    listTop = shuffleY + 2
    local listBottom = height - 1
    local rows = math.max(1, listBottom - listTop + 1)
    if selected < 1 then selected = 1 end
    if selected < scroll then scroll = selected end
    if selected > scroll + rows - 1 then scroll = selected - rows + 1 end
    if scroll < 1 then scroll = 1 end

    for row = 0, rows - 1 do
        local index = scroll + row
        local y = listTop + row
        if y > listBottom then break end
        local path = tracks[index]
        local bg, fg = colours.black, colours.white
        if index == selected then
            bg, fg = colours.lightBlue, colours.white
        elseif path and path == playingPath then
            fg = colours.lime
        end
        fill(y, bg)
        if path then
            local mark = (path == playingPath) and "> " or "  "
            put(1, y, (mark .. titleOf(path)):sub(1, width), bg, fg)
            addHit(1, y, width, 1, "track:" .. index)
        end
    end

    fill(height, colours.black)
    local foot = status
    if #speakers == 0 then foot = "Wire speakers on both sides. " .. status end
    put(1, height, (" " .. foot):sub(1, width), colours.black, colours.yellow)
end

local function reloadPlaylist()
    status = "Loading list..."
    draw()
    local list, err = fetchTracks()
    refreshSpeakers()
    if list then
        tracks = list
        saveCache()
        rebuildOrder()
        if selected > #tracks then selected = 1 end
        status = string.format("%d tracks", #tracks)
    else
        status = "List failed: " .. tostring(err)
    end
end

local function onControl(id, x)
    if id == "prev" then
        playRelative(-1)
    elseif id == "next" then
        playRelative(1)
    elseif id == "back" then
        seekBy(-10)
    elseif id == "fwd" then
        seekBy(10)
    elseif id == "play" then
        togglePause()
    elseif id == "shuffle" then
        toggleShuffle()
    elseif id == "voldown" then
        changeVolume(-0.1)
    elseif id == "volup" then
        changeVolume(0.1)
    elseif id == "seek" then
        local width = screen.getSize()
        local inner = math.max(1, width - 2)
        local frac = (x - 2) / inner
        if frac < 0 then frac = 0 end
        if frac > 1 then frac = 1 end
        if totalBytes > 0 then seekTo(frac * totalBytes) end
    elseif id:sub(1, 6) == "track:" then
        playIndex(tonumber(id:sub(7)), 0)
    end
end

local function uiLoop(monitorName)
    draw()
    while not quit do
        local event, a, b, c = os.pullEvent()
        local redraw = false
        if event == "monitor_touch" and a == monitorName then
            local id = hitAt(b, c)
            if id then onControl(id, b) end
            redraw = true
        elseif event == "key" then
            local key = a
            if key == keys.space then togglePause()
            elseif key == keys.left then seekBy(-10)
            elseif key == keys.right then seekBy(10)
            elseif key == keys.n then playRelative(1)
            elseif key == keys.p then playRelative(-1)
            elseif key == keys.up and selected > 1 then selected = selected - 1
            elseif key == keys.down and selected < #tracks then selected = selected + 1
            elseif key == keys.enter then playIndex(selected, 0)
            elseif key == keys.s then toggleShuffle()
            elseif key == keys.equals or key == keys.numPadAdd then changeVolume(0.1)
            elseif key == keys.minus or key == keys.numPadSubtract then changeVolume(-0.1)
            elseif key == keys.r then reloadPlaylist()
            elseif key == keys.q then
                quit = true
                session = session + 1
                closeStream()
                stopSpeakers()
            end
            redraw = true
        elseif event == "player_draw" or event == "monitor_resize" or event == "term_resize" then
            redraw = true
        end
        if redraw and not quit then
            local ok, err = pcall(draw)
            if not ok then status = tostring(err) end
        end
    end
end

local function main()
    math.randomseed(os.epoch("utc"))
    local onMonitor, monitorName = prepareScreen()
    refreshSpeakers()
    local hadCache = loadCache()
    if hadCache then
        status = "Cache found, refreshing..."
        rebuildOrder()
        pcall(draw)
    end
    local list, err = fetchTracks()
    if list then
        tracks = list
        saveCache()
        rebuildOrder()
        status = onMonitor and "Tap a track" or "No monitor, use the computer"
    elseif hadCache then
        status = "Using cache: " .. tostring(err)
    else
        status = "No playlist: " .. tostring(err)
    end
    if #speakers == 0 then
        status = "No speakers. " .. status
    end

    local native = term.current()
    term.redirect(term.native())
    term.clear()
    term.setCursorPos(1, 1)
    print(onMonitor and "Player on the 3x4 monitor" or "Monitor not found")
    print("Speakers: " .. #speakers)
    print("q quit, space pause, left/right seek")
    term.redirect(native)

    parallel.waitForAny(function() uiLoop(monitorName) end, audioLoop)

    paint(colours.black, colours.white)
    screen.clear()
    screen.setCursorPos(1, 1)
    screen.write("Player off")
    term.redirect(term.native())
    term.clear()
    term.setCursorPos(1, 1)
    print("Player stopped")
end

main()
