--[[
	UP Deck Lua script
	Author: John Craig
	Version: 2.1.20
	Released: 2020-03-03
	
	Notes:
		countdown timers update
		update line break text
		text source line breaks
		trigger added to fade
		pause countdown timers
--]]


local obs = obslua
local ffi = require("ffi")
local obsffi
local msgPath, repPath
local app2obs, obs2app, obs2dsk
local buff = ""
local buffDsk = ""
local interval = 5
local hotkey = {}
local debug = false
local sfxCmd
local sfxPath
local sfx = false
local unix = true
local dragItem
local prevScene
local replays = {}
local repSrc = "UP DECK REPLAY"
local repPfx = "Replay"
local countdown = {}
local syncdown = {}
local syncInit = false
local anim, animQ = {}, {}
local animRef, animReset = 0, 0
local animTag = {}
local lineBreak = "<br>"
local format = string.format
local scrSwitch = {}
local timerId = 0
local listen -- forward declaration


ffi.cdef[[

struct obs_source;
struct obs_properties;
struct obs_property;
typedef struct obs_source obs_source_t;
typedef struct obs_properties obs_properties_t;
typedef struct obs_property obs_property_t;

obs_source_t *obs_get_source_by_name(const char *name);
obs_source_t *obs_source_get_filter_by_name(obs_source_t *source, const char *name);
obs_properties_t *obs_source_properties(const obs_source_t *source);
obs_property_t *obs_properties_first(obs_properties_t *props);
bool obs_property_next(obs_property_t **p);
const char *obs_property_name(obs_property_t *p);
void obs_properties_destroy(obs_properties_t *props);
void obs_source_release(obs_source_t *source);

]]


if ffi.os == "OSX" then
	obsffi = ffi.load("obs.0.dylib")
else
	obsffi = ffi.load("obs")
end


-- constants are not available for lua :(
local obsAlignment = {
	center = 0, -- OBS_ALIGN_CENTER
	left   = 1, -- OBS_ALIGN_LEFT
	right  = 2, -- OBS_ALIGN_RIGHT
	top    = 4, -- OBS_ALIGN_TOP
	bottom = 8, -- OBS_ALIGN_BOTTOM
}


local obsBoundsType = {
	none    = 0, --OBS_BOUNDS_NONE - No bounding box
	stretch = 1, --OBS_BOUNDS_STRETCH - Stretch to the bounding box without preserving aspect ratio
	inner   = 2, --OBS_BOUNDS_SCALE_INNER - Scales with aspect ratio to inner bounding box rectangle
	outer   = 3, --OBS_BOUNDS_SCALE_OUTER - Scales with aspect ratio to outer bounding box rectangle
	width   = 4, --OBS_BOUNDS_SCALE_TO_WIDTH - Scales with aspect ratio to the bounding box width
	height  = 5, --OBS_BOUNDS_SCALE_TO_HEIGHT - Scales with aspect ratio to the bounding box height
	max     = 6, --OBS_BOUNDS_MAX_ONLY
}


local obsOrderMove = {
	up     = 0, --OBS_ORDER_MOVE_UP
	down   = 1, --OBS_ORDER_MOVE_DOWN
	top    = 2, --OBS_ORDER_MOVE_TOP
	bottom = 4, --OBS_ORDER_MOVE_BOTTOM
}


local function findSource(list, name)
	for i, s in ipairs(list) do
		if obs.obs_source_get_name(s) == name then
			return s
		end
	end
	return nil
end


local function findSceneItem(sceneName, itemName, groupName)
	local source = obs.obs_get_source_by_name(sceneName)
	local item = nil
	if source then
		local scene = obs.obs_scene_from_source(source)
		if scene then
			item = obs.obs_scene_find_source(scene, itemName)
			if not item and groupName then
				local group = obs.obs_scene_find_source(scene, groupName)
				if group then 
					scene = obs.obs_sceneitem_group_get_scene(group)
					if scene then
						item = obs.obs_scene_find_source(scene, itemName)
					end
				end
			end
		end
		obs.obs_source_release(source)
	end
	return item
end


local function currentSceneName()
	local source = obs.obs_frontend_get_current_scene()
	local name = obs.obs_source_get_name(source)
	obs.obs_source_release(source)
	return name
end


local function allSceneNames()
	local sceneNames = {}
	local scenes = obs.obs_frontend_get_scenes()
	for _, scene in ipairs(scenes) do
		sceneNames[#sceneNames + 1] = obs.obs_source_get_name(scene)
	end
	obs.source_list_release(scenes)
	return sceneNames
end


local function emptyScene(scene)
	local items = obs.obs_scene_enum_items(scene)
	if items then
		if debug then obs.script_log(obs.LOG_INFO, format("Clearing %d scene items", #items)) end
		for i, item in ipairs(items) do
			obs.obs_sceneitem_remove(item)
		end
		obs.sceneitem_list_release(items)
	end
end


local function copyUpdeckFilters(dest)
	local source = obs.obs_get_source_by_name("UP DECK")
	if source and dest then
		obs.obs_source_copy_filters(dest, source)
		obs.obs_source_release(source)
	end
	return nil
end


local function filterProperties(sourceName, filterName)
	local filterProps = {}
	
	local source = obsffi.obs_get_source_by_name(sourceName)
	if tostring(source):sub(-4) == "NULL" then
		return nil, format("No source named '%s'", sourceName)
	end

	local fSource = obsffi.obs_source_get_filter_by_name(source, filterName)
	obsffi.obs_source_release(source)
	if tostring(fSource):sub(-4) == "NULL" then
		return nil, format("Source '%s' has no filter named '%s'", sourceName, filterName)
	end

	local props = obsffi.obs_source_properties(fSource)
	obsffi.obs_source_release(fSource)
	if tostring(props):sub(-4) ~= "NULL" then
		local prop = obsffi.obs_properties_first(props)
		if tostring(prop):sub(-4) ~= "NULL" then
			local name = ffi.string(obsffi.obs_property_name(prop))
			filterProps[#filterProps + 1] = { name = name }
			local _p = ffi.new("obs_property_t *[1]", prop)
			local foundProp = obsffi.obs_property_next(_p)
			while foundProp do
				prop = ffi.new("obs_property_t *", _p[0])
				name = ffi.string(obsffi.obs_property_name(prop))
				obs.script_log(obs.LOG_INFO, name)
				filterProps[#filterProps + 1] = { name = name }
				foundProp = obsffi.obs_property_next(_p)
			end
		end
		obsffi.obs_properties_destroy(props)
	end
	return filterProps, ""
end


local function nextAnimId()
	animRef = animRef + 1
	return animRef
end


function ls(folder)
  	local i, files = 0, {}
    local dir = io.popen(unix and 'ls -1p "'..folder..'"' or 'dir /b /a-d /on "'..folder..'"')
    if dir then
	    for file in dir:lines() do
	    	i = i + 1
	        files[i] = file
	    end
	    dir:close()
	end
    return files
end


local function writeFile(path, data)
	local f, err = io.open(path, "wb")
	if f then
		f:write(data)
		f:close()
	end
end


local function send(msg)
	buff = buff..msg.."\n"
end


local function sendDsk(msg)
	buffDsk = buffDsk..msg.."\n"
end


local function fetchReplaysWin()
	replays = {}
	local path = msgPath.."/Win/"..math.floor(os.clock() * 1000)..".bat"
	local data = 'dir /b /a-d /on "'..repPath..'" > "'..msgPath..'/replays.txt"\ndel %0 *>nul'
	writeFile(path, data)
	obs.timer_add(
		function()
			local fileList = ""
			local i = 0
			for f in io.lines(msgPath..'/replays.txt') do
				if f:lower():match("^"..repPfx:lower()..".+[^/]$") then
					i = i + 1
					replays[i] = repPath.."\\"..f
					if fileList ~= "" then fileList = fileList.."\t" end
					fileList = fileList..f
					if debug then obs.script_log(obs.LOG_INFO, "Replay: "..f) end
				end
			end
			if i > 0 then send("replays\t"..#replays.."\t"..fileList) end
			obs.remove_current_callback()
		end,
		200
	)
	return nil
end


local function fetchReplays()
	if not unix then return fetchReplaysWin() end
	local i = 0
	local s = unix and "/" or "\\"
	local fileList = ""
	replays = {}
	local files = ls(repPath)
	if files then
		for _, f in ipairs(files) do
			if f:lower():match("^"..repPfx:lower()..".+[^/]$") then
				i = i + 1
				replays[i] = repPath..s..f
				if fileList ~= "" then fileList = fileList.."\t" end
				fileList = fileList..f
				if debug then obs.script_log(obs.LOG_INFO, "Replay: "..f) end
			end
		end
	end
	return fileList
end


local function minsSecs(secs)
	local m = math.floor( secs / 60 )
	local s = secs - m * 60
	return format("%02d:%02d", m, s)
end


local function process(cData)
	local vParams = {}
	local iParams = {}
	for field in string.gmatch(cData, "[^\t]+") do
		local l = field:len()
		local i = field:find("=", 1, true)
		if i and i > 1 and i < l then
			vParams[field:sub(1, i - 1)] = field:sub(i + 1)
		else
			iParams[#iParams + 1] = field
		end
	end

	local cmd = (iParams[1] or ""):lower()

	if cmd == "vol" then
		-- set volume
		if vParams.val then
			local val = tonumber(vParams.val) or 0
			val = format("%0.3f", math.pow(val, 3))
			for i = 2, #iParams do
				local name = iParams[i] or ""
				local source = obs.obs_get_source_by_name(name)
				if source then
					obs.obs_source_set_volume(source, val)
					obs.obs_source_release(source)
				end
			end
		end
	elseif cmd == "fade" then
		-- fade volume
		local volume = tonumber(vParams.volume) or 0
		local steps = tonumber(vParams.steps)
		local interval = tonumber(vParams.interval)
		local cb = vParams.trigger
		local dev = vParams.device
		if volume < 0 then volume = 0 elseif volume > 1 then volume = 1 end
		if steps and interval then
			if steps < 1 then steps = 1 end
			if interval < 1 then interval = 1 end
			for i = 2, #iParams do
				local name = iParams[i] or ""
				local source = obs.obs_get_source_by_name(name)
				if source then
					local vol = obs.obs_source_get_volume(source) or 0
					vol = format("%0.3f", math.pow(vol, 1 / 3))
					local inc = (volume - vol) / steps
					local step = 1
					obs.timer_add(
						function()
							vol = vol + inc
							obs.obs_source_set_volume(source, math.pow(vol, 3))
							step = step + 1
							if step > steps then
								obs.obs_source_release(source)
								if cb then send(format("trigger\t%s\t%s", cb, dev)) end
								obs.remove_current_callback()
							end
						end,
						interval
					)
				end
			end
		end
	elseif cmd == "mute" then
		-- source mute / unmute / toggle
		local val = vParams.val or ""
		local toggle = false
		if val == "0" then
			val = false
		elseif val == "1" then
			val = true
		else
			toggle = true
		end
		for i = 2, #iParams do
			local name = iParams[i] or ""
			local source = obs.obs_get_source_by_name(name)
			if source then
				if toggle then
					val = not obs.obs_source_muted(source)
				end
				obs.obs_source_set_muted(source, val)
				obs.obs_source_release(source)
				send( format("mute\t%s\t%d", name, val and 1 or 0) )
			end
		end
	elseif cmd == "show" then
		-- scene item visibility
		local val = vParams.val or ""
		local toggle = false
		if val == "0" then
			val = false
		elseif val == "1" then
			val = true
		else
			toggle = true
		end
		local sceneName = vParams.scene or ""
		if sceneName == "_current" then sceneName = currentSceneName() end
		if sceneName == "_all" then
			sceneNames = allSceneNames()
		else
			sceneNames = { sceneName }
		end
		for _, sceneName in ipairs(sceneNames) do
			for i = 2, #iParams do
				local itemName = iParams[i] or ""
				local sceneItem = findSceneItem(sceneName, itemName, vParams.group)
				if sceneItem then
					if toggle then
						val = not obs.obs_sceneitem_visible(sceneItem)
					end
					obs.obs_sceneitem_set_visible(sceneItem, val)
				end
			end
		end
	elseif cmd == "move" or cmd == "animate" then
		-- animate scene item properties
		local sceneName = vParams.scene
		local itemName = vParams.item
		local relative = {}
		for _, _p in ipairs({"x", "y", "w", "h", "r", "cl", "cr", "ct", "cb", "sw", "sh", "alpha"}) do
			if vParams[_p] and vParams[_p]:match("^%(%-?[%d.]+%)$") then
				relative[_p] = true
				vParams[_p] = tonumber(vParams[_p]:sub(2, -2)) or 0
			end
		end
		local x = tonumber(vParams.x)
		local y = tonumber(vParams.y)
		local w = tonumber(vParams.w)
		local h = tonumber(vParams.h)
		local r = tonumber(vParams.r)
		local cl = tonumber(vParams.cl)
		local cr = tonumber(vParams.cr)
		local ct = tonumber(vParams.ct)
		local cb = tonumber(vParams.cb)
		local sw = tonumber(vParams.sw)
		local sh = tonumber(vParams.sh)
		local morphScene = vParams.morphScene or vParams.scene2
		local morph = vParams.morph
		local alpha = tonumber(vParams.alpha)
		local steps = tonumber(vParams.steps) or 1
		local interval = tonumber(vParams.interval) or 2
		local easing = string.lower(vParams.easing or "")
		local exp = tonumber(vParams.exp) or 4
		local boundsType = vParams.bounds
		local move = x or y
		local resize = w or h or sw or sh
		local crop = cl or cr or ct or cb
		local queue = tonumber(vParams.queue)
		local reset = tonumber(vParams.reset)
		local delay = tonumber(vParams.delay)
		local tag = vParams.tag
		if not sceneName or not itemName then return false end
		if sceneName == "_current" then sceneName = currentSceneName() end
		local sceneItem = findSceneItem(sceneName, itemName, vParams.group)
		if not sceneItem then return false end
		local source = obs.obs_sceneitem_get_source(sceneItem)
		-- check for filters
		local filters, filter = {}, false
		for f = 1, 5 do
			local fName = vParams["filter"..f]
			if fName then
				local fSource = obs.obs_source_get_filter_by_name(source, fName)
				if fSource then
					filter = true
					filters[fName] = { source = fSource, params = {} }
					-- filter parameters
					for i, v in ipairs(iParams) do
						if v:sub(1, 3) == "f"..f..":" then
							local data = tostring(v:sub(4))
							local dLen = data:len() 
							local dPos = data:find(":", 1, true)
							local pName, pVal
							if dPos and dPos > 1 and dPos < dLen then
								pName = data:sub(1, dPos - 1)
								pVal = data:sub(dPos + 1)
							end
							if pName and pVal then
								filters[fName].params[pName] = {}
								if pVal:match("^%(%-?[%d.]+%)$") then
									filters[fName].params[pName].relative = true
									pVal = tonumber(pVal:sub(2, -2)) or 0
								else
									pVal = tonumber(pVal) or 0
								end
								filters[fName].params[pName].val = pVal
								if debug then obs.script_log(obs.LOG_INFO, format("Filter%d %s = %s", f, pName, pVal)) end
							end
						end
					end -- check vParams for filter params
				end -- filter source exists
			end
		end

		-- qtag parameter can define the animation id - default is scene/item
		local animObject = vParams.qtag or format("%s/%s", sceneName, itemName)
		
		if queue then
			if queue == 0 then
				animQ[animObject] = nil
			else
				if not animQ[animObject] then
					animQ[animObject] = {}
					anim[animObject] = nil
				end
			end
		end
		if reset then
			animReset = nextAnimId()
			anim[animObject] = nil
			animQ[animObject] = animQ[animObject] and {} or nil
		end
		local animId
		if vParams.animId then
			animId = tonumber(vParams.animId) or 0
		elseif animQ[animObject] then 
			animId = nextAnimId()
		else
			animId = animReset
		end

		-- update text / image
		if vParams.text or vParams.image then
			local s = obs.obs_data_create()
			s = obs.obs_source_get_settings(source)
			if vParams.text then obs.obs_data_set_string(s, "text", vParams.text) end
			if vParams.image then obs.obs_data_set_string(s, "file", vParams.image) end
			obs.obs_source_update(source, s)
			obs.obs_data_release(s)
		end

		-- check if OK to animate
		if not ((morph or move or resize or crop or r or alpha or filter) and steps and interval) then
			-- release any source references for filters
			for fName in pairs(filters) do
				if filters[fName].source then obs.obs_source_release(filters[fName].source) end
			end
			return false
		end

		-- check for tag & check if already processed
		if tag and not vParams.xtag then animTag[tag] = (animTag[tag] or 0) + 1 end

		if anim[animObject] and anim[animObject] ~= animId and animQ[animObject] then
			-- add to queue with flag for tag processed
			table.insert(animQ[animObject], cData.."\txtag=1")
			if debug then obs.script_log(obs.LOG_INFO, format("%s queue : %0d", animObject, #animQ[animObject])) end
			return false
		end

		anim[animObject] = animId
		if delay then
			-- remove the delay parameter and add flag for tag processed
			local cDataMod = cData:gsub("delay=%d+", "animId="..animId).."\txtag=1"
			if delay < 1 then delay = 1 end
			obs.timer_add(
				function()
					process(cDataMod)
					obs.remove_current_callback()
				end,
				delay
			)
		else
			if morph then
				local mTarget = findSceneItem(morphScene or sceneName, morph, vParams.morphGroup or vParams.group)
				if mTarget then
					local mSource = obs.obs_sceneitem_get_source(mTarget)
					local sWidth = obs.obs_source_get_width(mSource)
					local sHeight = obs.obs_source_get_height(mSource)
					local vec2 = obs.vec2()
					obs.obs_sceneitem_get_pos(mTarget, vec2)
					x, y = vec2.x, vec2.y
					obs.obs_sceneitem_get_bounds(mTarget, vec2)
					w, h = vec2.x, vec2.y
					obs.obs_sceneitem_get_scale(mTarget, vec2)
					sw, sh = sWidth * vec2.x, sHeight * vec2.y
					local crp = obs.obs_sceneitem_crop()
					obs.obs_sceneitem_get_crop(sceneItem, crp)
					cl, cr, ct, cb = crp.left, crp.right, crp.top, crp.bottom
					r = obs.obs_sceneitem_get_rot(mTarget)
					move, resize = true, true
					relative = {}
				else
					sceneItem = nil
				end
			end
			local align
			for i = 2, #iParams do
				local p = string.lower(iParams[i] or "_")
				if obsAlignment[p] then align = (align or 0) + obsAlignment[p] end
			end
			if align then obs.obs_sceneitem_set_alignment(sceneItem, align) end
			if boundsType and obsBoundsType[boundsType] then
				obs.obs_sceneitem_set_bounds_type(sceneItem, obsBoundsType[boundsType])
			end
			local cFilter
			if alpha then
				cFilter = obs.obs_source_get_filter_by_name(source, "UP DECK COLOR")
				if not cFilter then
					copyUpdeckFilters(source)
					cFilter = obs.obs_source_get_filter_by_name(source, "UP DECK COLOR")
				end
			end
			local pos = obs.vec2()
			local size = obs.vec2()
			local scale = obs.vec2()
			local crp = obs.obs_sceneitem_crop()
			local anData = {}
			-- easing formulae improved by starting at zero
			local step = 0
			steps = steps - 1
			if steps < 1 then steps = 1 end
			if move then
				obs.obs_sceneitem_get_pos(sceneItem, pos)
				if x then
					anData.startX = pos.x
					anData.distX = relative.x and x or x - anData.startX
				end
				if y then
					anData.startY = pos.y
					anData.distY = relative.y and y or y - anData.startY
				end
			end
			if resize then
				obs.obs_sceneitem_get_bounds(sceneItem, size)
				if w then
					anData.startW = size.x
					anData.distW = relative.w and w or w - anData.startW
				end
				if h then
					anData.startH = size.y
					anData.distH = relative.h and h or h - anData.startH
				end

				obs.obs_sceneitem_get_scale(sceneItem, scale)
				if sw then
					local sWidth = obs.obs_source_get_width(source)
					local targetScale = sWidth == 0 and 0 or sw / sWidth 
					anData.startSW = scale.x
					anData.distSW = relative.sw and targetScale or targetScale - anData.startSW 
				end
				if sh then
					local sHeight = obs.obs_source_get_height(source)
					local targetScale = sHeight == 0 and 0 or sh / sHeight 
					anData.startSH = scale.y
					anData.distSH = relative.sh and targetScale or targetScale - anData.startSH
				end
			end
			if crop then
				obs.obs_sceneitem_get_crop(sceneItem, crp)
				if cl then
					anData.startCL = crp.left
					anData.distCL = relative.cl and cl or cl - anData.startCL
				end
				if cr then
					anData.startCR = crp.right
					anData.distCR = relative.cr and cr or cr - anData.startCR
				end
				if ct then
					anData.startCT = crp.top
					anData.distCT = relative.ct and ct or ct - anData.startCT
				end
				if cb then
					anData.startCB = crp.bottom
					anData.distCB = relative.cb and cb or cb - anData.startCB
				end
			end
			if r then
				anData.startR = obs.obs_sceneitem_get_rot(sceneItem)
				anData.distR = relative.r and r or r - anData.startR
			end
			if alpha and cFilter then
				local s = obs.obs_data_create()
				s = obs.obs_source_get_settings(cFilter)
				anData.startA = obs.obs_data_get_int(s, "opacity") or 100
				obs.obs_data_release(s)
				anData.distA = relative.alpha and alpha or alpha - anData.startA
			end
			for fName in pairs(filters) do
				if filters[fName].source then
					local s = obs.obs_data_create()
					s = obs.obs_source_get_settings(filters[fName].source)
					for k, v in pairs(filters[fName].params) do
						v.start = obs.obs_data_get_double(s, k)
						v.dist = v.relative and v.val or v.val - v.start
					end
					obs.obs_data_release(s)
				end
			end
			obs.timer_add(
				function()
					if (anim[animObject] ~= animId) or (animId < animReset) then
						obs.remove_current_callback()
						if tag then animTag[tag] = math.max((animTag[tag] or 0) - 1, 0) end
						return nil
					end
					local progress
					local stepped = step / steps
					if easing == "easein" then
						progress = math.pow(stepped, exp)
					elseif easing == "easeout" then
						progress = 1 - math.pow(1 - stepped, exp)
					elseif easing == "easeinout" then
						if stepped < 0.5 then
							progress = math.pow(stepped * 2, exp) * 0.5
						else
							progress = 1 - math.pow((1 - stepped) * 2, exp) * 0.5
						end
					elseif easing == "easeoutin" then
						if stepped < 0.5 then
							progress = (1 - math.pow(1 - stepped * 2, exp)) * 0.5
						else
							progress = math.pow(stepped * 2 - 1, exp) * 0.5 + 0.5
						end
					elseif easing == "easeoutelastic" then
						local q = 0.5
						progress = math.pow(2, -10 * stepped) * math.sin((stepped - q * 0.25) * (2 * math.pi) / q) + 1
					else
						progress = step / steps
					end
					if move then
						if x then pos.x = anData.startX + progress * anData.distX end
						if y then pos.y = anData.startY + progress * anData.distY end
						obs.obs_sceneitem_set_pos(sceneItem, pos)
					end
					if resize then
						if w then size.x = anData.startW + progress * anData.distW end
						if h then size.y = anData.startH + progress * anData.distH end
						obs.obs_sceneitem_set_bounds(sceneItem, size)

						if sw then scale.x = anData.startSW + progress * anData.distSW end
						if sh then scale.y = anData.startSH + progress * anData.distSH end
						obs.obs_sceneitem_set_scale(sceneItem, scale)
					end
					if crop then
						if cl then crp.left = anData.startCL + progress * anData.distCL end
						if cr then crp.right = anData.startCR + progress * anData.distCR end
						if ct then crp.top = anData.startCT + progress * anData.distCT end
						if cb then crp.bottom = anData.startCB + progress * anData.distCB end
						obs.obs_sceneitem_set_crop(sceneItem, crp)
					end
					if r then
						r = anData.startR + progress * anData.distR
						obs.obs_sceneitem_set_rot(sceneItem, r)
					end
					if alpha and cFilter then
						alpha = anData.startA + progress * anData.distA
						local s = obs.obs_data_create()
						s = obs.obs_source_get_settings(cFilter)
						obs.obs_data_set_int(s, "opacity", alpha)
						obs.obs_source_update(cFilter, s)
						obs.obs_data_release(s)
					end
					for fName in pairs(filters) do
						if filters[fName].source then
							local s = obs.obs_data_create()
							s = obs.obs_source_get_settings(filters[fName].source)
							for k, v in pairs(filters[fName].params) do
								obs.obs_data_set_double(s, k, v.start + progress * v.dist)
								obs.obs_source_update(filters[fName].source, s)
							end
							obs.obs_data_release(s)
						end
					end
					step = step + 1
					if step > steps then
						if cFilter then obs.obs_source_release(cFilter) end
						for fName in pairs(filters) do
							if filters[fName].source then obs.obs_source_release(filters[fName].source) end
						end
						if animQ[animObject] then
							anim[animObject] = nil
							if #animQ[animObject] > 0 then
								local nextAnim = table.remove(animQ[animObject], 1)
								if debug then obs.script_log(obs.LOG_INFO, format("%s queue : %0d", animObject, #animQ[animObject])) end
								obs.timer_add(
									function()
										process(nextAnim)
										obs.remove_current_callback()
									end,
									1
								)
							end
						end
						if tag then animTag[tag] = math.max((animTag[tag] or 0) - 1, 0) end
						obs.remove_current_callback()
					end
				end,
				interval
			)
		end -- delay or immediate
	elseif cmd == "switch" then
		-- switch scene / switch transition or both
		local transition = vParams.trans or "_none"
		local transitions = obs.obs_frontend_get_transitions()
		transition = findSource(transitions, transition)
		if transition then obs.obs_frontend_set_current_transition(transition) end
		local name = vParams.scene or "_none"
		if name == "_previous" and prevScene then name = prevScene end
		prevScene = currentSceneName()
		local scenes = obs.obs_frontend_get_scenes()
		local scene = findSource(scenes, name)
		if scene then obs.obs_frontend_set_current_scene(scene) end
		obs.source_list_release(scenes)
		obs.source_list_release(transitions)
	elseif cmd == "obsfx" and iParams[2] then
		-- sfx flag : OBS or desktop app
		sfx = iParams[2] == "1"
		if debug then obs.script_log(obs.LOG_INFO, "OBS sfx: "..tostring(sfx)) end
	elseif (cmd == "sfx" or cmd == "play") then
		if sfx then
			if sfxPath and sfxCmd and sfxPath ~= "" and sfxCmd ~= "" then
				-- play sound fx
				local pre, post
				if unix then
					pre, post = "", " &"
					local cl = pre .. sfxCmd .. ' "' .. sfxPath .. '/' .. (iParams[2] or '_dummy_') .. '"' .. post
					if debug then obs.script_log(obs.LOG_INFO, cl) end
					os.execute(cl)
				else
					-- handle via script
					local path = msgPath.."/Win/"..math.floor(os.clock() * 1000)..".bat"
					local data = '"'..sfxCmd..'" "'..sfxPath..'/'..iParams[2]..'"\ndel %0 *>nul'
					writeFile(path, data)
				end
			end
		else
			-- pass to desktop app
			sendDsk(cData)
		end
	elseif cmd == "stop" then
		-- stop named process
		os.execute('killall -STOP ' .. iParams[2] or '_dummy_')
	elseif cmd == "cont" then
		-- resume named process
		os.execute('killall -CONT ' .. iParams[2] or '_dummy_')
	elseif cmd == "update" then
		for i = 3, #iParams do
			local name = iParams[i] or ""
			local source = obs.obs_get_source_by_name(name)
			if source then
				local volume = obs.obs_source_get_volume(source) or 0
				local muted = obs.obs_source_muted(source) or false
				send( format("vol\t%s\t%0.3f\nmute\t%s\t%d", name, volume, name, muted and 1 or 0) )
				obs.obs_source_release(source)
			end
		end
		send( format("stream\t%d", obs.obs_frontend_streaming_active() and 1 or 0) )
		send( format("record\t%d", obs.obs_frontend_recording_active() and 1 or 0) )
		send( format("replaybuffer\t%d", obs.obs_frontend_replay_buffer_active() and 1 or 0) )
	elseif cmd == "studio" then
		local active = vParams.active
		if active == "*" then
			active = not obs.obs_frontend_preview_program_mode_active()
		elseif active == "0" then
			active = false
		else
			active = true
		end
		print("a="..tostring(active))
		obs.obs_frontend_set_preview_program_mode(false)
	elseif cmd == "stream" then
		if iParams[2] == "start" then 
			if not obs.obs_frontend_streaming_active() then obs.obs_frontend_streaming_start() end
		elseif iParams[2] == "stop" then
			if obs.obs_frontend_streaming_active() then obs.obs_frontend_streaming_stop() end
		else
			if obs.obs_frontend_streaming_active() then
				obs.obs_frontend_streaming_stop()
			else
				obs.obs_frontend_streaming_start()
			end
		end
	elseif cmd == "record" then
		if iParams[2] == "start" then
			if not obs.obs_frontend_recording_active() then obs.obs_frontend_recording_start() end
		elseif iParams[2] == "stop" then
			if obs.obs_frontend_recording_active() then obs.obs_frontend_recording_stop() end
		else
			if obs.obs_frontend_recording_active() then
				obs.obs_frontend_recording_stop()
			else
				obs.obs_frontend_recording_start()
			end
		end
	elseif cmd == "replaybuffer" then
		if iParams[2] == "start" then
			if not obs.obs_frontend_replay_buffer_active() then obs.obs_frontend_replay_buffer_start() end
		elseif iParams[2] == "stop" then
			if obs.obs_frontend_replay_buffer_active() then obs.obs_frontend_replay_buffer_stop() end
		else
			if obs.obs_frontend_replay_buffer_active() then
				obs.obs_frontend_replay_buffer_stop()
			else
				obs.obs_frontend_replay_buffer_start()
			end
		end
	elseif cmd == "position" or cmd == "resize" or cmd == "rotate" or cmd == "opacity" then
		-- set anchor point / position / size / bounds type
		local sceneName = vParams.scene
		local itemName = vParams.item
		local boundsType = vParams.bounds
		local relative = {}
		for _, _p in ipairs({"x", "y", "w", "h", "r", "cl", "cr", "ct", "cb", "sx", "sy", "sw", "sh", "alpha"}) do
			if vParams[_p] and vParams[_p]:match("^%(%-?[%d.]+%)$") then
				relative[_p] = true
				vParams[_p] = tonumber(vParams[_p]:sub(2, -2)) or 0
			end
		end
		local x = tonumber(vParams.x)
		local y = tonumber(vParams.y)
		local w = tonumber(vParams.w)
		local h = tonumber(vParams.h)
		local r = tonumber(vParams.r)
		local cl = tonumber(vParams.cl)
		local cr = tonumber(vParams.cr)
		local ct = tonumber(vParams.ct)
		local cb = tonumber(vParams.cb)
		local sx = tonumber(vParams.sx)
		local sy = tonumber(vParams.sy)
		local sw = tonumber(vParams.sw)
		local sh = tonumber(vParams.sh)
		local alpha = tonumber(vParams.alpha)
		local morphScene = vParams.morphScene or vParams.scene2
		local morph = vParams.morph
		if not sceneName or not itemName then return false end
		if sceneName == "_current" then sceneName = currentSceneName() end
		local sceneItem = findSceneItem(sceneName, itemName, vParams.group)
		if morph then
			local mTarget = findSceneItem(morphScene or sceneName, morph, vParams.morphGroup or vParams.group)
			if morph then
				local vec2 = obs.vec2()
				obs.obs_sceneitem_get_pos(mTarget, vec2)
				x, y = vec2.x, vec2.y
				obs.obs_sceneitem_get_bounds(mTarget, vec2)
				w, h = vec2.x, vec2.y
				local crp = obs.obs_sceneitem_crop()
				obs.obs_sceneitem_get_crop(sceneItem, crp)
				cl, cr, ct, cb = crp.left, crp.right, crp.top, crp.bottom
				r = obs.obs_sceneitem_get_rot(mTarget)
				relative = {}
			else
				sceneItem = nil
			end
		end
		if not sceneItem then return false end
		local align
		for i = 2, #iParams do
			local p = string.lower(iParams[i] or "_")
			if obsAlignment[p] then align = (align or 0) + obsAlignment[p] end
		end
		if align then obs.obs_sceneitem_set_alignment(sceneItem, align) end
		if boundsType and obsBoundsType[boundsType] then
			obs.obs_sceneitem_set_bounds_type(sceneItem, obsBoundsType[boundsType])
		end
		local cFilter
		if alpha then
			local source = obs.obs_sceneitem_get_source(sceneItem)
			cFilter = obs.obs_source_get_filter_by_name(source, "UP DECK COLOR")
			if not cFilter then
				copyUpdeckFilters(source)
				cFilter = obs.obs_source_get_filter_by_name(source, "UP DECK COLOR")
			end
			if cFilter then
				local s = obs.obs_data_create()
				s = obs.obs_source_get_settings(cFilter)
				local currentAlpha = obs.obs_data_get_int(s, "opacity") or 100
				obs.obs_data_set_int(s, "opacity", relative.alpha and currentAlpha + alpha or alpha)
				obs.obs_source_update(cFilter, s)
				obs.obs_data_release(s)
				obs.obs_source_release(cFilter)
			end
		end
		if x or y then
			local pos = obs.vec2()
			obs.obs_sceneitem_get_pos(sceneItem, pos)
			if x then pos.x = relative.x and pos.x + x or x end
			if y then pos.y = relative.y and pos.y + y or y end
			obs.obs_sceneitem_set_pos(sceneItem, pos)
		end
		if w or h then
			local size = obs.vec2()
			obs.obs_sceneitem_get_bounds(sceneItem, size)
			if w then size.x = relative.w and size.x + w or w end
			if h then size.y = relative.h and size.y + h or h end
			obs.obs_sceneitem_set_bounds(sceneItem, size)
		end
		if cl or cr or ct or cb then
			local crp = obs.obs_sceneitem_crop()
			obs.obs_sceneitem_get_crop(sceneItem, crp)
			if cl then crp.left = relative.cl and crp.left + cl or cl end
			if cr then crp.right = relative.cr and crp.right + cr or cr end
			if ct then crp.top = relative.ct and crp.top + ct or ct end
			if cb then crp.bottom = relative.cb and crp.bottom + cb or cb end
			obs.obs_sceneitem_set_crop(sceneItem, crp)
		end
		if r then
			if relative.r then r = obs.obs_sceneitem_get_rot(sceneItem) + r end
			obs.obs_sceneitem_set_rot(sceneItem, r)
		end
		if sx or sy then
			local scale = obs.vec2()
			obs.obs_sceneitem_get_scale(sceneItem, scale)
			if sx then scale.x = relative.sx and scale.x + sx or sx end
			if sy then scale.y = relative.sy and scale.y + sy or sy end
			obs.obs_sceneitem_set_scale(sceneItem, scale)
		end
		if sw or sh then
			local scale = obs.vec2()
			obs.obs_sceneitem_get_scale(sceneItem, scale)
			local source = obs.obs_sceneitem_get_source(sceneItem)
			local sWidth = obs.obs_source_get_width(source)
			local sHeight = obs.obs_source_get_height(source)
			local iWidth = sWidth * scale.x
			local iHeight = sHeight * scale.y
			if sw then
				if relative.sw then sw = iWidth + sw end
				scale.x = sWidth == 0 and 0 or sw / sWidth
			end
			if sh then
				if relative.sh then sh = iHeight + sh end
				scale.y = sHeight == 0 and 0 or sh / sHeight
			end
			obs.obs_sceneitem_set_scale(sceneItem, scale)
		end
	elseif cmd == "order" then
		-- change scene item layer / order position
		local sceneName = vParams.scene
		local itemName = vParams.item
		if sceneName and itemName then
			if sceneName == "_current" then sceneName = currentSceneName() end
			local sceneItem = findSceneItem(sceneName, itemName, vParams.group)
			if sceneItem then
				for i = 2, #iParams do
					local ps = string.lower(iParams[i] or "_")
					local pi = tonumber(iParams[i])
					if obsOrderMove[ps] then
						obs.obs_sceneitem_set_order(sceneItem, obsOrderMove[ps])
					elseif pi then
						obs.obs_sceneitem_set_order_position(sceneItem, pi)
					end
				end
			end
		end
	elseif cmd == "filter" then
		-- enable / disable filter
		local sceneName = vParams.scene
		local itemName = vParams.item
		local filterName = vParams.filter
		local active = vParams.active
		if sceneName and itemName and filterName and active then
			if sceneName == "_current" then sceneName = currentSceneName() end
			local sceneItem = findSceneItem(sceneName, itemName, vParams.group)
			if sceneItem then
				local source = obs.obs_sceneitem_get_source(sceneItem)
				local filter = obs.obs_source_get_filter_by_name(source, filterName)
				if filter then
					if active == "*" then
						active = not obs.obs_source_enabled(filter)
					elseif active == "1" then
						active = true
					else
						active = false
					end
					obs.obs_source_set_enabled(filter, active)
					obs.obs_source_release(filter)
				end
			end
		end
	elseif cmd == "currentitems" then
		local source = obs.obs_frontend_get_current_scene()
		if source then
			local response = "currentitems\t"..obs.obs_source_get_name(source)
			local scene = obs.obs_scene_from_source(source)
			obs.obs_source_release(source)
			local items = obs.obs_scene_enum_items(scene) or {}
			for k, v in ipairs(items) do
				source = obs.obs_sceneitem_get_source(v)
				response = response.."\t"..obs.obs_source_get_name(source)
			end
			obs.sceneitem_list_release(items)
			send(response)
		end
	elseif cmd == "dragitem" then
		-- dragpad scene item select
		dragItem = nil
		local sceneName = vParams.scene or iParams[2]
		local sceneItem = vParams.item or iParams[3]
		if sceneName and sceneItem then
			if sceneName == "_current" then sceneName = currentSceneName() end
			dragItem = findSceneItem(sceneName, sceneItem, vParams.group)
			dragSource = obs.obs_sceneitem_get_source(dragItem)
			--obs.obs_sceneitem_set_bounds_type(dragItem, obsBoundsType.outer)
			--obs.obs_sceneitem_set_alignment(dragItem, obsAlignment.center)
			--obs.obs_sceneitem_set_order(dragItem, obsOrderMove.top)
			local size = obs.vec2()
			obs.obs_sceneitem_get_bounds(dragItem, size)
			if size.x < 10 or size.y < 10 then
				size.x, size.y = 120, 120
				obs.obs_sceneitem_set_bounds(dragItem, size)
			end
		end
		send("dragitem\t"..(dragSource and sceneItem or ""))
	elseif cmd == "drag" and dragItem then
		-- dragpad
		local dx = tonumber(vParams.x)
		local dy = tonumber(vParams.y)
		local ds = tonumber(vParams.s)
		local dr = tonumber(vParams.r)
		local d  = tonumber(vParams.d)
		if dx or dy then
			local pos = obs.vec2()
			obs.obs_sceneitem_get_pos(dragItem, pos)
			if dx then pos.x = pos.x + dx end
			if dy then pos.y = pos.y + dy end
			obs.obs_sceneitem_set_pos(dragItem, pos)
			if d then sendDsk("draw\tx="..math.floor(pos.x + 0.5).."\ty="..math.floor(pos.y + 0.5)) end
		end
		if ds then
			local size = obs.vec2()
			obs.obs_sceneitem_get_bounds(dragItem, size)
			local w = size.x * ds
			local h = size.y * ds
			if w < 10 then w = 10 elseif w > 2000 then w = 2000 end
			if h < 10 then h = 10 elseif h > 2000 then h = 2000 end
			size.x, size.y = w, h
			obs.obs_sceneitem_set_bounds(dragItem, size)
		end
		if dr then
			obs.obs_sceneitem_set_rot(dragItem, obs.obs_sceneitem_get_rot(dragItem) + dr)
		end
	elseif cmd == "getobjdata" then
		-- get scene item data
		local sceneName = vParams.scene
		local itemName = vParams.item
		if sceneName and itemName then
			local sceneItem = findSceneItem(sceneName, itemName, vParams.group)
			if sceneItem then
				local pos = obs.vec2()
				local bounds = obs.vec2()
				obs.obs_sceneitem_get_pos(sceneItem, pos)
				obs.obs_sceneitem_get_bounds(sceneItem, bounds)
				local anchor = obs.obs_sceneitem_get_alignment(sceneItem)
				if debug then
					obs.script_log(
						obs.LOG_INFO,
						format(
							"%s / %s\nPos: %0.2f,%0.2f\nSize: %0.2f,%0.2f\nAnchor: %d",
							sceneName, itemName, pos.x, pos.y, bounds.x, bounds.y, anchor
						)
					)
				end
				send(format("objdata\t%s\t%s\t%0d\t%0d\t%0d\t%0d\t%d", sceneName, itemName, pos.x, pos.y, bounds.x, bounds.y, anchor))
			end
		end
	elseif cmd == "cdpause" then
		-- set / unset / toggle pause for 1 or more synced countdown timers
		local val = vParams.val or ""
		local toggle = false
		if val == "0" then
			val = false
		elseif val == "1" then
			val = true
		else
			toggle = true
		end
		for i = 2, #iParams do
			local cd = syncdown[iParams[i]]
			if cd then
				if toggle then
					val = not cd.pause
				end
				cd.pause = val
			end	
		end
	elseif cmd == "countdown" then
		local sourceName = vParams.source or ""
		local cb = vParams.trigger
		local up = vParams.up and val
		local neg = vParams.negative
		local secs = vParams.seconds
		local dev = vParams.device
		if sourceName then iParams[#iParams + 1] = sourceName end
		for i = 2, #iParams do
			local sourceName = iParams[i]
			local source = obs.obs_get_source_by_name(sourceName)
			local val = tonumber(vParams.val) or 10
			-- check for relative value
			if vParams.val and vParams.val:match("^%(%-?[%d.]+%)$") then
				val = math.max(0, (syncdown[sourceName] and syncdown[sourceName].val or 0) + (tonumber(vParams.val:sub(2, -2)) or 0))
			end
			if source and val then
				if not syncInit then
					obs.timer_add(
						function()
							--if debug then obs.script_log(obs.LOG_INFO, "Syncdown...") end
							for sourceName, cd in pairs(syncdown) do
								local s = obs.obs_get_source_by_name(sourceName)
								if s then
									if not cd.pause then
										cd.val = ( tonumber(cd.val) or 0 ) - 1
										local t = cd.val
										if t < 0 then
											if cd.cb then send(format("trigger\t%s\t%s", cd.cb, cd.dev)) end
											syncdown[sourceName] = nil
											if debug then obs.script_log(obs.LOG_INFO, format("Syncdown complete : %s", sourceName)) end
										else
											if cd.up then t = cd.up - t end
											if not cd.secs then t = minsSecs(t) end
											if cd.neg then t = "-"..t end
											local set = obs.obs_data_create()
											set = obs.obs_source_get_settings(s)
											obs.obs_data_set_string(set, "text", t)
											obs.obs_source_update(s, set)
											obs.obs_data_release(set)
										end
									end
									obs.obs_source_release(s)
								else
									syncdown[sourceName] = nil
									if debug then obs.script_log(obs.LOG_INFO, format("Syncdown error : %s", sourceName)) end
								end
							end -- syncdown
						end,
						1000
					)
					syncInit = true
				end
				syncdown[sourceName] = { val=val, cb=cb, up=up, neg=neg, secs=secs, dev=dev, pause=false }
				local t = up and 0 or val
				if not secs then t = minsSecs(t) end
				if neg then t = "-"..t end
				local set = obs.obs_data_create()
				set = obs.obs_source_get_settings(source)
				obs.obs_data_set_string(set, "text", t)
				obs.obs_source_update(source, set)
				obs.obs_data_release(set)
				obs.obs_source_release(source)
			end -- iParams
		end
	elseif cmd == "counter" then
		-- use text source as counter / scoreboard
		local source = obs.obs_get_source_by_name(vParams.source or "")
		if source then
			local s = obs.obs_data_create()
			s = obs.obs_source_get_settings(source)
			local v = 0
			if vParams.reset then
				v = tonumber(vParams.reset) or 0
			else
				v = tonumber(obs.obs_data_get_string(s, "text") or "") or 0
				if vParams.add then v = v + (tonumber(vParams.add) or 0) end
				if vParams.subtract then v = v - (tonumber(vParams.subtract) or 0) end
			end
			local digits = tonumber(vParams.digits) or 0
			v = (digits and digits > 1) and format("%0"..digits.."d", v) or tostring(v)
			obs.obs_data_set_string(s, "text", v)
			obs.obs_source_update(source, s)
			obs.obs_data_release(s)
			obs.obs_source_release(source)
		end
	elseif cmd == "linebreak" then
		-- update line break code
		lineBreak = vParams.text or "<br>"
	elseif cmd == "text" then
		-- update source text
		if vParams["break"] then
			lineBreak = vParams["break"] or "<br>"
		end
		local source = obs.obs_get_source_by_name(vParams.source or "")
		local text = (vParams.text or ""):gsub(lineBreak, "\n")
		if source and vParams.text then
			local s = obs.obs_data_create()
			s = obs.obs_source_get_settings(source)
			obs.obs_data_set_string(s, "text", text)
			obs.obs_source_update(source, s)
			obs.obs_data_release(s)
			obs.obs_source_release(source)
		end
	elseif cmd == "image" then
		-- update image
		local source = obs.obs_get_source_by_name(vParams.source or "")
		if source and vParams.file then
			local s = obs.obs_data_create()
			s = obs.obs_source_get_settings(source)
			obs.obs_data_set_string(s, "file", vParams.file)
			obs.obs_source_update(source, s)
			obs.obs_data_release(s)
			obs.obs_source_release(source)
		end
	elseif cmd == "media" then
		-- update media source
		local source = obs.obs_get_source_by_name(vParams.source or "")
			if source and vParams.file then
				local settings = obs.obs_data_create()
				local sourceId = obs.obs_source_get_id(source)
				if sourceId == "ffmpeg_source" then
					-- set target file and speed
					obs.obs_data_set_string(settings, "local_file", vParams.file)
					obs.obs_data_set_bool(settings, "is_local_file", true)
					obs.obs_data_set_int(settings, "speed_percent", vParams.speed or 100)
					obs.obs_source_update(source, settings)
				end
				obs.obs_data_release(settings)
				obs.obs_source_release(source)
			end
	elseif cmd == "list" and vParams.file then
		local f, err = io.open(msgPath.."/Lists/"..vParams.file..".txt", "rb")
		if f then
			send("list\tstart\t"..vParams.file)
			local line
			for line in f:lines() do
				send("list\tdata\t"..line)
			end
			send("list\tend")
			f:close()
		else
			send("list\terror\t"..vParams.file)
		end
	elseif cmd == "replays" and repPath then
		repPfx = vParams.files or ""
		local fileList = fetchReplays()
		if fileList then send("replays\t"..#replays.."\t"..fileList) end
	elseif cmd == "replay" and repPath then
		local index = vParams.index or 0
		if index == "first" then
			index = 1
		elseif index == "last" then
			index = #replays
		end
		index = tonumber(index) or 0
		if index < 0 then index = #replays + index + 1 end
		if index < 1 or index > #replays then index = nil end
		if vParams.source then repSrc = vParams.source end
		if vParams.action == "select" then
			if vParams.files then repPfx = vParams.files end
		elseif vParams.action == "save" then
			obs.obs_frontend_replay_buffer_save()
		elseif vParams.action == "play" and index then
			local source = obs.obs_get_source_by_name(repSrc or "")
			if source then
				local settings = obs.obs_data_create()
				local sourceId = obs.obs_source_get_id(source)
				if sourceId == "vlc_source" and not vParams.stop then
					-- set playlist to target file
					local dataArray = obs.obs_data_array_create()
					local iStart, iEnd = index, index
					if vParams.all then
						iStart, iEnd = 1, #replays
					end
					for i = iStart, iEnd do
						local data = obs.obs_data_create()
						obs.obs_data_set_string(data, "value", replays[i])
						obs.obs_data_array_push_back(dataArray, data)
						obs.obs_data_release(data)
					end
					obs.obs_data_set_array(settings, "playlist", dataArray)
					obs.obs_source_update(source, settings)
					obs.obs_data_array_release(dataArray)
				elseif sourceId == "ffmpeg_source" then
					-- set target file and speed
					local filename = vParams.stop and "" or replays[index]
					obs.obs_data_set_string(settings, "local_file", filename)
					obs.obs_data_set_bool(settings, "is_local_file", true)
					obs.obs_data_set_int(settings, "speed_percent", vParams.speed or 100)
					obs.obs_source_update(source, settings)
				end
				obs.obs_data_release(settings)
				obs.obs_source_release(source)
			end
		elseif vParams.action == "delete" and index then
			os.remove(replays[index])
			local fileList = fetchReplays()
			if fileList then send("replays\t"..#replays.."\t"..fileList) end
		elseif vParams.action == "wipe" then
			for index = 1, #replays do
				os.remove(replays[index])
			end
			local fileList = fetchReplays()
			if fileList then send("replays\t"..#replays.."\t"..fileList) end
		end
	elseif cmd == "filterprops" then
		local source = vParams.source or ""
		local filter = vParams.filter or ""
		local props, msg = filterProperties(source, filter)
		if props then
			msg = format("%s / %s properties : ", source, filter)
			for i, p in ipairs(props) do
				obs.script_log(obs.LOG_INFO, p)
				if i > 1 then msg = msg..", " end
				msg = msg..p.name
			end
		end
		send(format("alert\tFilter Properties\t%s", msg))
	elseif cmd == "scriptswitch" then
		local env = {
			currentSceneName = currentSceneName,
			findSceneItem = findSceneItem,
			emptyScene = emptyScene,
			findSource = findSource,
			prevScene = prevScene,
			scrSwitch = scrSwitch,
			vParams = vParams,
			format = format,
			listen = listen,
			ipairs = ipairs,
			debug = debug,
			obs = obs,
			obsAlignment = obsAlignment,
			obsBoundsType = obsBoundsType,
			animTag = animTag,
			msgPath = msgPath,
		}
		local trans, msg = loadfile(msgPath.."/Transitions/"..(vParams.trans or "_")..".lua", "bt", env)
		if not trans then
			obs.script_log(obs.LOG_INFO, format("Transition error : %s", msg))
			return false
		end
		local success, msg = pcall(trans)
		if not success then
			obs.script_log(obs.LOG_INFO, format("Transition error : %s", msg))
			return false
		end
		env.scriptTransition()
	elseif cmd == "fetchprops" and vParams.scene and vParams.item then
		local sceneName = vParams.scene or ""
		if sceneName == "_current" then sceneName = currentSceneName() end
		local item = findSceneItem(sceneName, vParams.item, vParams.group)
		if not item then
			if debug then obs.script_log(obs.LOG_INFO, format("fetchprops : no scene item %s/%s", vParams.scene, vParams.item)) end
			return false
		end
		local pos = obs.vec2()
		local bounds = obs.vec2()
		local text = ""
		obs.obs_sceneitem_get_pos(item, pos)
		obs.obs_sceneitem_get_bounds(item, bounds)
		local s = obs.obs_data_create()
		local source = obs.obs_sceneitem_get_source(item)
		s = obs.obs_source_get_settings(source)
		if s then
			text = obs.obs_data_get_string(s, "text") or ""
			obs.obs_data_release(s)
		end
		local total = 0
		local response = "props"
		for k, v in pairs({ x = pos.x, y = pos.y, bw = bounds.x, bh = bounds.y, text = text }) do
			local var = (vParams[k] or ""):match("^%s*([%w_]+)%s*$")
			if var then
				total = total + 1
				response = response..format("\t%s=%s", var, v)
			end
		end
		if total > 0 then
			send(response)
			if debug then obs.script_log(obs.LOG_INFO, format("fetchprops %s/%s = %s", sceneName, vParams.item, response)) end
		end
	end
end


listen = function(msg, tId)
	-- if the script has reloaded then stop any old timers
	if tId and tId < timerId then
		obs.remove_current_callback()
		return
	end
	-- process outgoing data first
	if obs2app and buff and buff ~= "" then
		local f, err = io.open(obs2app, "rb")
		if f then
			f:close()
		else
			f, err = io.open(obs2app, "wb")
			if f then
				local success, err = f:write(buff)
				if success then buff = "" end
				f:close()
			end
		end
	end
	if obs2dsk and buffDsk and buffDsk ~= "" then
		local f, err = io.open(obs2dsk, "rb")
		if f then
			f:close()
		else
			f, err = io.open(obs2dsk, "wb")
			if f then
				local success, err = f:write(buffDsk)
				if success then buffDsk = "" end
				f:close()
			end
		end
	end

	if not app2obs then return nil end

	if not msg then
		local f, err = io.open(app2obs, "rb")
		if f then
			msg = f:read("*all")
			f:close()
			if not os.remove(app2obs) then msg = nil end
		end
	end
	if not msg then return nil end

	if debug then obs.script_log(obs.LOG_INFO, format("Received : %s", msg)) end

	if msg:len() > 1 then
		-- process command list
		local cmds = {}
		for field in string.gmatch(msg, "[^\n]+") do
			cmds[#cmds + 1] = field
		end
		for cIndex, cData in ipairs(cmds) do
			-- check for animate command : special case will handle own delay
			local cmd = cData:match("^%a+") or ""
			local animation = (cmd == "animate") or (cmd == "move")
			-- check for delayed or immediate execution
			local delay = cData:match("\tdelay=%d+")
			if not animation and delay then
				delay = tonumber(delay:sub(8)) or 1
				if delay < 1 then delay = 1 end
				obs.timer_add(
					function()
						process(cData)
						obs.remove_current_callback()
					end,
					delay
				)
			else
				process(cData)
			end
		end
	end
end


local function onHotKey(id)
	if debug then obs.script_log(obs.LOG_INFO, format("Hotkey : %d", id)) end
	if obs2app then
		local cData
		local f, err = io.open(msgPath.."/Actions/"..id..".txt", "rb")
		if f then
			cData = f:read("*all")
			f:close()
			listen(cData)
		end
	end
end


local function init()
	-- increase timer id - old timers will be cancelled
	timerId = timerId + 1
	if msgPath and msgPath ~= "" then
		app2obs = msgPath.."/app2obs"
		obs2app = msgPath.."/obs2app"
		obs2dsk = msgPath.."/obs2dsk"
		if msgPath:sub(2, 2) == ":" then unix = false end
	else
		app2obs = nil
		obs2app = nil
		obs2dsk = nil
	end
	local tId = timerId
	obs.timer_add(function() listen(nil, tId) end, interval)
	obs.script_log(obs.LOG_INFO, format("listening(id=%d) interval=%d...", timerId, interval))
end


----------------------------------------------------------


local function onMute(cd)
	if debug then obs.script_log(obs.LOG_INFO, "onMute") end
	local muted = obs.calldata_bool(cd, "mute")
	local source = obs.calldata_source(cd, "source")
	if source then
		local name = obs.obs_source_get_name(source)
		if name then
			send( format("mute\t%s\t%s", name, muted and "1" or "0") )
		end
	end
end


local function onVolume(cd)
	if debug then obs.script_log(obs.LOG_INFO, "onVolume") end
	local volume = obs.calldata_float(cd, "volume")
	local source = obs.calldata_source(cd, "source")
	if source then
		local name = obs.obs_source_get_name(source)
		local muted = obs.obs_source_muted(source) or false
		if name then
			send( format("vol\t%s\t%0.3f\nmute\t%s\t%s", name, volume, name, muted and "1" or "0") )
		end
	end
end


local function onSignal(signal, cd)
	if debug then obs.script_log(obs.LOG_INFO, format("Signal: %s", signal)) end
end


----------------------------------------------------------


-- called on startup
function script_load(settings)
	-- script_update called on load
	--init()
	--local sh = obs.obs_get_signal_handler()
	--obs.signal_handler_connect(sh, "mute", onMute) -- doesn't fire
	--obs.signal_handler_connect(sh, "source_volume", onVolume)
	--obs.signal_handler_connect_global(sh, onSignal)
	for i = 1, 100 do
		hotkey[i] = obs.obs_hotkey_register_frontend("UPDECK"..i, "UP Deck Hotkey "..i, function(pressed) if pressed then onHotKey(i) end end)
		local hotkeyArray = obs.obs_data_get_array(settings, "UPDECKHOTKEY"..i)
		obs.obs_hotkey_load(hotkey[i], hotkeyArray)
		obs.obs_data_array_release(hotkeyArray)
	end
end


-- called on unload
function script_unload()
	-- trying to clean up timer caused crash
	--obs.timer_remove(listen)
end


-- called when settings changed
function script_update(settings)
	--pass = obs.obs_data_get_string(settings, "pass")
	--port = obs.obs_data_get_int(settings, "port")
	msgPath = obs.obs_data_get_string(settings, "msgPath")
	interval = obs.obs_data_get_int(settings, "interval")
	debug = obs.obs_data_get_bool(settings, "debug")
	sfxCmd = obs.obs_data_get_string(settings, "sfxCmd")
	sfxPath = obs.obs_data_get_string(settings, "sfxPath")
	repPath = obs.obs_data_get_string(settings, "repPath")
	init()
end


-- return description shown to user
function script_description()
	return "Control deck for OBS Studio"
end


-- define properties that user can change
function script_properties()
	local props = obs.obs_properties_create()
	--obs.obs_properties_add_text(props, "pass", "Password", obs.OBS_TEXT_PASSWORD)
	--obs.obs_properties_add_int(props, "port", "Port", 1024, 65535, 1)
	obs.obs_properties_add_text(props, "msgPath", "Message Path", obs.OBS_TEXT_DEFAULT)
	obs.obs_properties_add_int(props, "interval", "Interval (ms)", 2, 500, 1)
	obs.obs_properties_add_text(props, "sfxCmd", "sfx Command", obs.OBS_TEXT_DEFAULT)
	obs.obs_properties_add_path(props, "sfxPath", "sfx Folder", obs.OBS_PATH_DIRECTORY, "", nil)
	obs.obs_properties_add_path(props, "repPath", "Replay Folder", obs.OBS_PATH_DIRECTORY, "", nil)
	obs.obs_properties_add_bool(props, "debug", "Debug")
	return props
end


-- set default values
function script_defaults(settings)
	--obs.obs_data_set_default_string(settings, "pass", "")
	--obs.obs_data_set_default_int(settings, "port", 4445)
	obs.obs_data_set_default_string(settings, "msgPath", "")
	obs.obs_data_set_default_int(settings, "interval", 5)
	obs.obs_data_set_default_string(settings, "sfxCmd", "")
	obs.obs_data_set_default_bool(settings, "debug", false)
end


-- save additional data not set by user
function script_save(settings)
	for i = 1, 100 do
		local hotkeyArray = obs.obs_hotkey_save(hotkey[i])
		obs.obs_data_set_array(settings, "UPDECKHOTKEY"..i, hotkeyArray)
		obs.obs_data_array_release(hotkeyArray)
	end
end