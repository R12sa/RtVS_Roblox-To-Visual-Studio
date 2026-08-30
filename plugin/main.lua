-- RtVS Plugin: Main Entry Point
local HttpService = game:GetService("HttpService")
local ScriptEditorService = game:GetService("ScriptEditorService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Deserializer = require(script.Parent.deserializer)
local StudioWatcher = require(script.Parent["studio-watcher"])
local PathUtils = require(script.Parent["path-utils"])

-- Wire up echo suppression: before the deserializer applies a change from the
-- file system, register it with StudioWatcher so the resulting Changed event
-- doesn't get re-sent back to the server.
Deserializer.onBeforeApply = function(filePath)
	StudioWatcher.suppressEcho(filePath)
end

local SERVER_URL = "http://localhost:8080"
local POLL_INTERVAL = 2
local PLUGIN_VERSION = "0.1.7"

local MAX_CHUNK_SIZE = 800000
local YIELD_INTERVAL = 100
local objectsProcessed = 0

local REQUEST_DELAY = 0.03
local MAX_REQUEST_RETRIES = 3
local lastRequestTime = 0

local syncProgress = {
	totalChunks = 0,
	sentChunks = 0,
	startTime = 0,
	lastProgressUpdate = 0
}

local versionMismatch = false
local lastFullSyncTime = 0
local RECENT_SYNC_THRESHOLD = 60 -- seconds

-- Per-sync stats for string sanitization (invalid UTF-8 in property/attribute values).
-- HttpService:JSONEncode rejects non-UTF-8 strings, so we swap them for a placeholder
-- rather than failing the entire sync. Reset at the start of readAllServices.
local sanitizeStats = {
	count = 0,
	examples = {}, -- up to 10 entries
}

local function isValidUtf8(s)
	return utf8.len(s) ~= nil
end

local function sanitizeString(value, contextHint)
	if isValidUtf8(value) then
		return value
	end
	sanitizeStats.count = sanitizeStats.count + 1
	if #sanitizeStats.examples < 10 and contextHint then
		table.insert(sanitizeStats.examples, contextHint)
	end
	return string.format("<binary data: %d bytes>", #value)
end

local SYNC_MODE = {
	NONE = "none",
	PRIORITIZE_STUDIO = "prioritize_studio",
	PRIORITIZE_SERVER = "prioritize_server",
	BIDIRECTIONAL = "bidirectional"
}

local currentMode = SYNC_MODE.NONE
local isPolling = false

-- Compare version strings (returns -1 if v1 < v2, 0 if equal, 1 if v1 > v2)
local function compareVersions(v1, v2)
	local v1Parts = {}
	local v2Parts = {}

	for num in string.gmatch(v1, "%d+") do
		table.insert(v1Parts, tonumber(num))
	end

	for num in string.gmatch(v2, "%d+") do
		table.insert(v2Parts, tonumber(num))
	end

	for i = 1, math.max(#v1Parts, #v2Parts) do
		local part1 = v1Parts[i] or 0
		local part2 = v2Parts[i] or 0

		if part1 < part2 then
			return -1
		elseif part1 > part2 then
			return 1
		end
	end

	return 0
end

-- Test server connection and check version compatibility
local function testConnection()
	local success, response = pcall(function()
		return HttpService:GetAsync(SERVER_URL .. "/ping")
	end)

	if not success then
		warn("RtVS Server not running - start it with 'npm start' in /server")
		warn("    Error:", response)
		return false
	end

	-- Parse response to get server version
	local data = HttpService:JSONDecode(response)

	if not data or not data.version then
		warn("RtVS Server responded but version information is missing")
		return false
	end

	local serverVersion = data.version
	local versionComparison = compareVersions(PLUGIN_VERSION, serverVersion)

	if versionComparison < 0 then
		-- Plugin version is lower than server version
		warn("========================================")
		warn("OUTDATED PLUGIN")
		warn("========================================")
		warn("Outdated Plugin!! Please reinstall from GitHub:")
		warn("https://github.com/R12sa/RtVS_Roblox-To-Visual-Studio")
		warn("")
		warn("Download RtVS.rbxm and place it in your Plugins folder:")
		warn("  Windows: %LOCALAPPDATA%\\Roblox\\Plugins\\")
		warn("  macOS: ~/Documents/Roblox/Plugins/")
		warn("  Linux (Vinegar): ~/.var/app/org.vinegarhq.Vinegar/data/vinegar/prefixes/studio/drive_c/users/<you>/AppData/Local/Roblox/Plugins/")
		warn("")
		warn("Plugin functionality has been suspended.")
		warn("========================================")
		warn("Plugin Version: " .. PLUGIN_VERSION)
		warn("Server Version: " .. serverVersion)
		warn("========================================")
		versionMismatch = true
		return false
	elseif versionComparison > 0 then
		-- Plugin version is higher than server version
		warn("========================================")
		warn("OUTDATED SERVER")
		warn("========================================")
		warn("Outdated Server!! Please Update Via Github at")
		warn("https://github.com/R12sa/RtVS_Roblox-To-Visual-Studio/!!")
		warn("Plugin Functionality has been Suspended!!")
		warn("========================================")
		warn("Plugin Version: " .. PLUGIN_VERSION)
		warn("Server Version: " .. serverVersion)
		warn("========================================")
		versionMismatch = true
		return false
	end

	-- Versions match
	print("RtVS Server connected (v" .. serverVersion .. ")")

	-- Check if there's a newer version available
	if data.latestVersion and data.latestVersion ~= PLUGIN_VERSION then
		local latestComparison = compareVersions(PLUGIN_VERSION, data.latestVersion)

		if latestComparison < 0 then
			-- Plugin is outdated
			warn("========================================")
			warn("UPDATE AVAILABLE")
			warn("========================================")
			warn("A new version of RtVS is available!")
			warn("Current Version: " .. PLUGIN_VERSION)
			warn("Latest Version:  " .. data.latestVersion)
			warn("")
			warn("Download the latest version from GitHub:")
			warn("https://github.com/R12sa/RtVS_Roblox-To-Visual-Studio")
			warn("")
			warn("Replace the plugin file in your Plugins folder:")
			warn("  Windows: %LOCALAPPDATA%\\Roblox\\Plugins\\")
			warn("  macOS: ~/Documents/Roblox/Plugins/")
			warn("  Linux (Vinegar): ~/.var/app/org.vinegarhq.Vinegar/data/vinegar/prefixes/studio/drive_c/users/<you>/AppData/Local/Roblox/Plugins/")
			warn("========================================")
		end
	end

	versionMismatch = false
	return true
end

-- Close all open script editors to refresh them
-- This prevents users from being stuck in stale script editors when files change
local function closeAllScriptEditors()
	local success, error = pcall(function()
		-- Get all open script documents
		local documents = ScriptEditorService:GetScriptDocuments()

		for _, document in ipairs(documents) do
			-- Close the document
			pcall(function()
				document:CloseAsync()
			end)
		end

		if #documents > 0 then
			print("Closed", #documents, "script editors for refresh")
		end
	end)

	if not success then
		warn("Could not close script editors:", error)
	end
end

-- Poll server for file changes (Files → Studio)
local function pollForChanges()
	local success, response = pcall(function()
		return HttpService:GetAsync(SERVER_URL .. "/changes")
	end)

	if not success then
		-- Network error, silently fail and try again next poll
		return
	end

	-- Parse response
	local data = HttpService:JSONDecode(response)

	if not data or not data.changes then
		return
	end

	-- Apply each change
	if #data.changes > 0 then
		print("Received", #data.changes, "changes from server")

		-- Set undo waypoint before applying changes (enables Ctrl+Z rollback)
		ChangeHistoryService:SetWaypoint("RtVS: Before " .. #data.changes .. " file changes")

		for _, change in ipairs(data.changes) do
			local success, error = pcall(function()
				Deserializer.applyChange(change)
			end)

			if not success then
				warn("Failed to apply change:", error)
			end
		end

		-- Set waypoint after applying changes
		ChangeHistoryService:SetWaypoint("RtVS: Applied " .. #data.changes .. " file changes")

		print("Applied all changes (Ctrl+Z to undo)")
	end
end

-- Start polling for file changes (Prioritize Server mode)
local function startPolling()
	if isPolling then
		print("Already polling for changes")
		return
	end

	isPolling = true
	print("Started polling for file changes (every " .. POLL_INTERVAL .. "s)")

	-- Use a simple loop with task.spawn
	task.spawn(function()
		while isPolling do
			pollForChanges()
			task.wait(POLL_INTERVAL)
		end
	end)
end

-- Stop polling for file changes
local function stopPolling()
	if not isPolling then
		return
	end

	isPolling = false
	print("Stopped polling for file changes")
end

-- Helper function to serialize Vector3
local function serializeVector3(vector)
	return {
		X = vector.X,
		Y = vector.Y,
		Z = vector.Z
	}
end

-- Helper function to serialize Vector2
local function serializeVector2(vector)
	return {
		X = vector.X,
		Y = vector.Y
	}
end

-- Helper function to serialize Color3
local function serializeColor3(color)
	return {
		R = color.R,
		G = color.G,
		B = color.B
	}
end

-- Helper function to serialize CFrame
local function serializeCFrame(cf)
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	return {
		Position = {X = x, Y = y, Z = z},
		Components = {r00, r01, r02, r10, r11, r12, r20, r21, r22}
	}
end

-- Helper function to serialize common property types. contextHint is a human
-- path like "Workspace.Map.Tree.Properties.Attributes.Size_Curve" used only when
-- a string needs to be sanitized, so the end-of-sync summary can list locations.
local function serializeProperty(value, contextHint)
	local valueType = typeof(value)

	if valueType == "Vector3" then
		return serializeVector3(value)
	elseif valueType == "Vector2" then
		return serializeVector2(value)
	elseif valueType == "Color3" then
		return serializeColor3(value)
	elseif valueType == "CFrame" then
		return serializeCFrame(value)
	elseif valueType == "BrickColor" then
		return value.Name
	elseif valueType == "EnumItem" then
		return tostring(value)
	elseif valueType == "Instance" then
		return value:GetFullName()
	elseif valueType == "number" then
		-- JSONEncode rejects NaN and +/-inf; coerce to nil-safe sentinel
		if value ~= value or value == math.huge or value == -math.huge then
			return tostring(value)
		end
		return value
	elseif valueType == "boolean" then
		return value
	elseif valueType == "string" then
		return sanitizeString(value, contextHint)
	else
		return sanitizeString(tostring(value), contextHint)
	end
end

-- List of common properties to read
local commonProperties = {
	"Anchored", "CanCollide", "CastShadow", "Color", "Material",
	"Reflectance", "Transparency", "Size", "Position", "Orientation",
	"CFrame", "BrickColor", "Source", "Disabled", "PrimaryPart",
	"Brightness", "Ambient", "OutdoorAmbient", "ColorShift_Top", "ColorShift_Bottom",
	"Health", "MaxHealth", "WalkSpeed", "JumpPower",
}

-- Function to read properties of an instance
local function getInstanceProperties(instance)
	local properties = {}
	local instanceFullName = instance:GetFullName()

	for _, propName in ipairs(commonProperties) do
		local success, value = pcall(function()
			return instance[propName]
		end)

		if success and value ~= nil then
			properties[propName] = serializeProperty(value, instanceFullName .. "." .. propName)
		end
	end

	local attributes = instance:GetAttributes()
	if next(attributes) ~= nil then
		local serialized = {}
		for k, v in pairs(attributes) do
			serialized[k] = serializeProperty(v, instanceFullName .. ".Attributes." .. tostring(k))
		end
		properties.Attributes = serialized
	end

	return properties
end

-- Recursive function to serialize instance tree (with throttling)
local function serializeInstance(instance, skipChildren)
	-- Throttle to prevent Studio freeze
	objectsProcessed = objectsProcessed + 1
	if objectsProcessed % YIELD_INTERVAL == 0 then
		task.wait() -- Yield to let Studio breathe
	end

	local data = {
		ClassName = instance.ClassName,
		Name = instance.Name,
		Properties = getInstanceProperties(instance),
		Children = {}
	}

	if not skipChildren then
		for _, child in ipairs(instance:GetChildren()) do
			table.insert(data.Children, serializeInstance(child, false))
		end
	end

	return data
end

-- Count total objects
local function countObjects(data)
	local count = 1
	for _, child in ipairs(data.Children) do
		count = count + countObjects(child)
	end
	return count
end

-- Walk a value to pinpoint the field responsible for a JSONEncode failure.
-- Returns a human-readable path string, or nil if the value re-encodes cleanly.
-- For instance-shaped tables, descends into Children/Services using each element's
-- Name field so the reported path reads like Workspace.Map.Tree_03.Leaves rather
-- than Children.1.Children.5.Children.1.
local function diagnoseJsonError(data, path)
	path = path or "<root>"
	local wrapper = (type(data) == "table") and data or { data }
	local ok, err = pcall(function()
		HttpService:JSONEncode(wrapper)
	end)
	if ok then
		return nil
	end

	if type(data) ~= "table" then
		return string.format("%s (type=%s, value=%s): %s",
			path, typeof(data), string.sub(tostring(data), 1, 120), tostring(err))
	end

	local walkedKeys = {}

	local function walkChildList(list, listKeyName)
		if type(list) ~= "table" then
			return nil
		end
		for i, child in ipairs(list) do
			local label
			if type(child) == "table" and type(child.Name) == "string" then
				label = child.Name
			else
				label = listKeyName .. "[" .. i .. "]"
			end
			local childErr = diagnoseJsonError(child, path .. "." .. label)
			if childErr then
				return childErr
			end
		end
		return nil
	end

	if data.Children ~= nil then
		local e = walkChildList(data.Children, "Children")
		if e then return e end
		walkedKeys.Children = true
	end
	if data.Services ~= nil then
		local e = walkChildList(data.Services, "Services")
		if e then return e end
		walkedKeys.Services = true
	end

	for k, v in pairs(data) do
		if not walkedKeys[k] then
			local keyType = type(k)
			if keyType ~= "string" and keyType ~= "number" then
				return string.format("%s has non-string/number key (type=%s): %s",
					path, keyType, tostring(err))
			end
			local childErr = diagnoseJsonError(v, path .. "." .. tostring(k))
			if childErr then
				return childErr
			end
		end
	end

	return string.format("%s (table itself fails, possibly cyclic or mixed string/number keys): %s",
		path, tostring(err))
end

-- Get JSON size of data. On encode failure, warns with the offending path.
local function getJsonSize(data, contextName)
	local success, json = pcall(function()
		return HttpService:JSONEncode(data)
	end)
	if success then
		return #json
	end

	local label = contextName
		or (type(data) == "table" and data.Name)
		or "<unknown>"
	warn("Failed to JSON-encode " .. tostring(label) .. ": " .. tostring(json))
	local diag = diagnoseJsonError(data, tostring(label))
	if diag then
		warn("   Offending field: " .. diag)
	end
	return 0
end

-- Throttle HTTP requests to avoid rate limits
local function throttleRequest()
	local currentTime = tick()
	local timeSinceLastRequest = currentTime - lastRequestTime
	if timeSinceLastRequest < REQUEST_DELAY then
		task.wait(REQUEST_DELAY - timeSinceLastRequest)
	end
	lastRequestTime = tick()
end

local function postJsonWithRetry(endpoint, jsonPayload, label)
	local lastError = nil

	for attempt = 1, MAX_REQUEST_RETRIES do
		throttleRequest()

		local success, response = pcall(function()
			return HttpService:PostAsync(
				SERVER_URL .. endpoint,
				jsonPayload,
				Enum.HttpContentType.ApplicationJson
			)
		end)

		if success then
			return true, response
		end

		lastError = response
		if attempt < MAX_REQUEST_RETRIES then
			warn(string.format("%s failed (attempt %d/%d), retrying: %s",
				label,
				attempt,
				MAX_REQUEST_RETRIES,
				tostring(response)))
			task.wait(0.25 * attempt)
		end
	end

	return false, lastError
end

-- Count estimated chunks needed for an instance tree
local function countChunksNeeded(instanceData)
	local count = 0
	local instanceSize = getJsonSize(instanceData, instanceData and instanceData.Name)

	if instanceSize <= MAX_CHUNK_SIZE then
		-- Fits in one chunk
		return 1
	end

	-- Will need base chunk + children
	count = 1 -- Base chunk
	for _, childData in ipairs(instanceData.Children or {}) do
		count = count + countChunksNeeded(childData)
	end
	return count
end

-- Format time for ETA display
local function formatTime(seconds)
	if seconds < 60 then
		return string.format("%.0fs", seconds)
	elseif seconds < 3600 then
		local mins = math.floor(seconds / 60)
		local secs = math.floor(seconds % 60)
		return string.format("%dm %ds", mins, secs)
	else
		local hours = math.floor(seconds / 3600)
		local mins = math.floor((seconds % 3600) / 60)
		return string.format("%dh %dm", hours, mins)
	end
end

-- Update and display sync progress
local function updateProgress()
	syncProgress.sentChunks = syncProgress.sentChunks + 1

	local currentTime = tick()
	-- Only update display every 0.5 seconds to avoid spam
	if currentTime - syncProgress.lastProgressUpdate < 0.5 then
		return
	end
	syncProgress.lastProgressUpdate = currentTime

	local elapsed = currentTime - syncProgress.startTime
	local chunksRemaining = syncProgress.totalChunks - syncProgress.sentChunks
	local avgTimePerChunk = elapsed / syncProgress.sentChunks
	local eta = chunksRemaining * avgTimePerChunk

	local percent = math.floor((syncProgress.sentChunks / syncProgress.totalChunks) * 100)
	print(string.format("   Progress: %d/%d chunks (%d%%) - ETA: %s",
		syncProgress.sentChunks,
		syncProgress.totalChunks,
		percent,
		formatTime(eta)))
end

-- Reset progress tracking
local function resetProgress(totalChunks)
	syncProgress.totalChunks = totalChunks
	syncProgress.sentChunks = 0
	syncProgress.startTime = tick()
	syncProgress.lastProgressUpdate = 0
end

-- Start a chunked sync session
local function startChunkedSession(expectedServices)
	local success, response = postJsonWithRetry(
		"/sync/start",
		HttpService:JSONEncode({ expectedServices = expectedServices }),
		"Starting sync session"
	)

	if success then
		local data = HttpService:JSONDecode(response)
		return data.sessionId
	else
		warn("Failed to start sync session:", response)
		return nil
	end
end

-- Send a service chunk
local function sendServiceChunk(sessionId, serviceName, serviceData)
	local payload = {
		sessionId = sessionId,
		type = "service",
		serviceName = serviceName,
		serviceData = serviceData
	}
	local encodeOk, jsonPayload = pcall(function()
		return HttpService:JSONEncode(payload)
	end)
	if not encodeOk then
		warn("Failed to JSON-encode service chunk '" .. tostring(serviceName) .. "': " .. tostring(jsonPayload))
		local diag = diagnoseJsonError(serviceData, serviceName)
		if diag then
			warn("   Offending field: " .. diag)
		end
		return false
	end

	local success, response = postJsonWithRetry("/sync/chunk", jsonPayload, "Sending service chunk")

	if success then
		local data = HttpService:JSONDecode(response)
		if data.received then
			updateProgress()
		end
		return data.received
	else
		warn("Failed to send service chunk:", response)
		return false
	end
end

-- Send a Workspace chunk (flat children array)
local function sendWorkspaceChunk(sessionId, chunkIndex, totalChunks, children)
	local payload = {
		sessionId = sessionId,
		type = "workspace_chunk",
		chunkIndex = chunkIndex,
		totalChunks = totalChunks,
		children = children
	}
	local encodeOk, jsonPayload = pcall(function()
		return HttpService:JSONEncode(payload)
	end)
	if not encodeOk then
		warn(string.format("Failed to JSON-encode Workspace chunk %d/%d: %s",
			chunkIndex, totalChunks, tostring(jsonPayload)))
		local diag = diagnoseJsonError(children, "workspace.children")
		if diag then
			warn("   Offending field: " .. diag)
		end
		return false
	end

	local success, response = postJsonWithRetry("/sync/chunk", jsonPayload, "Sending Workspace chunk")

	if success then
		local data = HttpService:JSONDecode(response)
		return data.received
	else
		warn("Failed to send Workspace chunk:", response)
		return false
	end
end

-- Send a deep chunk (with path for nested objects)
local function sendDeepChunk(sessionId, parentPath, instanceData, skipProgress)
	local payload = {
		sessionId = sessionId,
		type = "deep_chunk",
		parentPath = parentPath,
		instanceData = instanceData
	}
	local instanceLabel = parentPath .. "/" .. (instanceData and instanceData.Name or "<unnamed>")
	local encodeOk, jsonPayload = pcall(function()
		return HttpService:JSONEncode(payload)
	end)
	if not encodeOk then
		warn("Failed to JSON-encode deep chunk '" .. instanceLabel .. "': " .. tostring(jsonPayload))
		local diag = diagnoseJsonError(instanceData, instanceLabel)
		if diag then
			warn("   Offending field: " .. diag)
		end
		return false
	end

	local success, response = postJsonWithRetry("/sync/chunk", jsonPayload, "Sending deep chunk")

	if success then
		local data = HttpService:JSONDecode(response)
		if data.received and not skipProgress then
			updateProgress()
		end
		return data.received
	else
		warn("Failed to send deep chunk:", response)
		return false
	end
end

-- Get sync status for file write progress
local function getSyncStatus(sessionId)
	local success, response = pcall(function()
		return HttpService:GetAsync(SERVER_URL .. "/sync/status/" .. sessionId)
	end)

	if success then
		local data = HttpService:JSONDecode(response)
		return data
	else
		return nil
	end
end

-- Complete a chunked sync session with progress tracking
local function completeChunkedSession(sessionId)
	print("Writing files to disk...")
	print("")

	-- Start the completion request
	local writeStartTime = tick()
	local lastStatusUpdate = 0

	-- Send the complete request (now returns immediately, writes in background)
	local success, response = postJsonWithRetry(
		"/sync/complete",
		HttpService:JSONEncode({ sessionId = sessionId }),
		"Completing sync session"
	)

	if not success then
		warn("Failed to start sync completion:", response)
		return false, 0
	end

	local completeResult = HttpService:JSONDecode(response)
	if not completeResult.success then
		warn("Server rejected sync completion:", completeResult.error or "Unknown error")
		return false, 0
	end

	-- Poll for status until complete or error
	-- The server now writes files in the background and we poll for progress
	local finalFilesWritten = 0

	while true do
		task.wait(0.3) -- Poll every 300ms

		local status = getSyncStatus(sessionId)
		if status then
			local currentTime = tick()

			-- Check for completion or error
			if status.phase == "complete" then
				finalFilesWritten = status.filesWritten or 0
				print(string.format("   Complete: %d files written", finalFilesWritten))
				return true, finalFilesWritten
			elseif status.phase == "error" then
				warn("File write failed:", status.error or "Unknown error")
				return false, 0
			end

			-- Update display every 0.5 seconds
			if currentTime - lastStatusUpdate >= 0.5 then
				lastStatusUpdate = currentTime

				if status.phase == "preparing" then
					print("   Preparing output directory...")
				elseif status.phase == "writing" then
					local percent = 0
					if status.totalFiles and status.totalFiles > 0 then
						percent = math.floor((status.filesWritten / status.totalFiles) * 100)
					end
					local elapsed = currentTime - writeStartTime
					local eta = 0
					if status.filesWritten and status.filesWritten > 0 then
						local avgTimePerFile = elapsed / status.filesWritten
						local filesRemaining = (status.totalFiles or 0) - status.filesWritten
						eta = filesRemaining * avgTimePerFile
					end
					local serviceInfo = ""
					if status.currentService then
						serviceInfo = " - " .. status.currentService
					end
					print(string.format("   Writing: %d/%d files (%d%%) - ETA: %s%s",
						status.filesWritten or 0,
						status.totalFiles or 0,
						percent,
						formatTime(eta),
						serviceInfo))
				end
			end
		end

		-- Timeout after 4 hours for very large projects
		if tick() - writeStartTime > 14400 then
			warn("File write operation timed out (4 hours)")
			return false, 0
		end
	end
end

-- Recursively send an instance and its children, chunking as needed
-- Returns true on success, false on failure
local function sendInstanceRecursive(sessionId, parentPath, instance, instanceData, depth)
	depth = depth or 0
	local indent = string.rep("   ", depth)

	local instancePath = parentPath .. "/" .. instanceData.Name
	local instanceSize = getJsonSize(instanceData, instancePath)

	-- If this instance fits within the limit, send it whole
	if instanceSize <= MAX_CHUNK_SIZE then
		local sent = sendDeepChunk(sessionId, parentPath, instanceData)
		if not sent then
			warn(indent .. "Failed to send: " .. instancePath)
			return false
		end
		return true
	end

	-- Instance is too big - send it without children, then recurse

	-- Send the instance without children
	local instanceBase = {
		ClassName = instanceData.ClassName,
		Name = instanceData.Name,
		Properties = instanceData.Properties,
		Children = {} -- Children sent separately
	}

	local baseSent = sendDeepChunk(sessionId, parentPath, instanceBase)
	if not baseSent then
		warn(indent .. "Failed to send base: " .. instancePath)
		return false
	end

	-- Now recursively send each child
	local children = instanceData.Children or {}
	local childrenToSend = {}
	local currentBatchSize = 0

	for i, childData in ipairs(children) do
		local childSize = getJsonSize(childData, instancePath .. "/" .. childData.Name)

		-- If this single child is too big, recurse into it
		if childSize > MAX_CHUNK_SIZE then
			-- First, flush any accumulated small children
			if #childrenToSend > 0 then
				for _, smallChild in ipairs(childrenToSend) do
					local sent = sendDeepChunk(sessionId, instancePath, smallChild)
					if not sent then
						warn(indent .. "   Failed to send small child: " .. smallChild.Name)
						return false
					end
				end
				childrenToSend = {}
				currentBatchSize = 0
			end

			-- Recurse into the large child
			local childInstance = instance:FindFirstChild(childData.Name)
			if not sendInstanceRecursive(sessionId, instancePath, childInstance, childData, depth + 1) then
				return false
			end
		else
			-- Small enough - accumulate for batch sending
			-- But if batch would exceed limit, flush first
			if currentBatchSize + childSize > MAX_CHUNK_SIZE and #childrenToSend > 0 then
				for _, batchChild in ipairs(childrenToSend) do
					local sent = sendDeepChunk(sessionId, instancePath, batchChild)
					if not sent then
						warn(indent .. "   Failed to send: " .. batchChild.Name)
						return false
					end
				end
				childrenToSend = {}
				currentBatchSize = 0
			end

			table.insert(childrenToSend, childData)
			currentBatchSize = currentBatchSize + childSize
		end

		-- Yield periodically during chunking to prevent freeze
		if i % 50 == 0 then
			task.wait()
		end
	end

	-- Send remaining accumulated children
	if #childrenToSend > 0 then
		for _, childData in ipairs(childrenToSend) do
			local sent = sendDeepChunk(sessionId, instancePath, childData)
			if not sent then
				warn(indent .. "   Failed to send: " .. childData.Name)
				return false
			end
		end
	end

	return true
end

-- Send JSON data to server (Full sync - legacy for small games)
local function sendToServer(jsonData)
	local success, response = pcall(function()
		return HttpService:PostAsync(
			SERVER_URL .. "/sync",
			jsonData,
			Enum.HttpContentType.ApplicationJson
		)
	end)

	if success then
		local responseData = HttpService:JSONDecode(response)
		print("Sync successful! Server wrote", responseData.filesWritten, "files")
		return true, responseData
	else
		warn("Sync failed:", response)
		return false, response
	end
end

-- Main function to read all game services and send to server
-- Uses chunked sync for large games, single request for small games
local function readAllServices()
	print("===== RtVS: Reading All Game Services =====")

	-- Reset throttle counter
	objectsProcessed = 0

	-- Reset per-sync string-sanitization stats
	sanitizeStats.count = 0
	sanitizeStats.examples = {}

	local success, result = pcall(function()
		local servicesToRead = {
			game.Workspace,
			game:GetService("ReplicatedStorage"),
			game:GetService("ReplicatedFirst"),
			game:GetService("ServerScriptService"),
			game:GetService("ServerStorage"),
			game:GetService("StarterGui"),
			game:GetService("StarterPack"),
			game:GetService("StarterPlayer"),
			game:GetService("Lighting"),
			game:GetService("SoundService"),
			game:GetService("Chat"),
			game:GetService("LocalizationService"),
			game:GetService("TestService"),
		}

		-- First pass: serialize all services and count objects
		print("Serializing game data (this may take a moment for large games)...")
		local serializedServices = {}
		local totalObjects = 0
		local totalSize = 0

		for _, service in ipairs(servicesToRead) do
			print("Reading " .. service.ClassName .. "...")
			local serviceData = serializeInstance(service, false)
			local objectCount = countObjects(serviceData)

			-- Yield before size calculation to prevent freeze
			task.wait()
			local serviceSize = getJsonSize(serviceData, service.ClassName)

			table.insert(serializedServices, {
				service = service,
				data = serviceData,
				objectCount = objectCount,
				size = serviceSize
			})

			totalObjects = totalObjects + objectCount
			totalSize = totalSize + serviceSize
			print("   " .. service.ClassName .. ": " .. objectCount .. " objects, " .. math.floor(serviceSize/1024) .. "KB")

			-- Yield between services
			task.wait()
		end

		print("")
		print("Total objects: " .. totalObjects)
		print("Total size: " .. math.floor(totalSize/1024) .. "KB")

		-- Decide whether to use chunked sync
		local needsChunking = totalSize > MAX_CHUNK_SIZE
		if not needsChunking then
			for _, s in ipairs(serializedServices) do
				if s.size > MAX_CHUNK_SIZE then
					needsChunking = true
					break
				end
			end
		end

		if needsChunking then
			print("")
			print("Large game detected - using deep chunked sync...")
			print("")

			-- Count total chunks needed for progress tracking
			print("Calculating chunks needed...")
			local totalChunksNeeded = 0
			for _, s in ipairs(serializedServices) do
				if s.size > MAX_CHUNK_SIZE then
					-- Will need base chunk + recursive children
					totalChunksNeeded = totalChunksNeeded + 1 -- base chunk
					for _, childData in ipairs(s.data.Children or {}) do
						totalChunksNeeded = totalChunksNeeded + countChunksNeeded(childData)
					end
				else
					totalChunksNeeded = totalChunksNeeded + 1 -- single service chunk
				end
				task.wait() -- Yield to prevent freeze
			end
			print("Total chunks to send: " .. totalChunksNeeded)
			print("")

			-- Initialize progress tracking
			resetProgress(totalChunksNeeded)

			-- Start chunked session
			local sessionId = startChunkedSession(#servicesToRead)
			if not sessionId then
				warn("Failed to start chunked sync session")
				return nil
			end

			print("Started sync session: " .. string.sub(sessionId, 1, 8) .. "...")
	print("Request delay: " .. REQUEST_DELAY .. "s between requests")
			print("")

			-- Send each service
			for i, s in ipairs(serializedServices) do
				local serviceName = s.service.ClassName

				-- Check if this service needs deep chunking
				if s.size > MAX_CHUNK_SIZE then
					-- Use deep recursive chunking
					print("Deep chunking " .. serviceName .. " (" .. math.floor(s.size/1024) .. "KB)...")

					-- Send service base (without children)
					local serviceBase = {
						ClassName = s.data.ClassName,
						Name = s.data.Name,
						Properties = s.data.Properties,
						Children = {} -- Children sent separately via deep chunks
					}
					local baseSent = sendServiceChunk(sessionId, serviceName, serviceBase)
					if not baseSent then
						warn("Failed to send " .. serviceName .. " base")
						return nil
					end

					-- Recursively send children using deep chunking
					for _, childData in ipairs(s.data.Children or {}) do
						local childInstance = s.service:FindFirstChild(childData.Name)
						if not sendInstanceRecursive(sessionId, serviceName, childInstance, childData, 1) then
							warn("Failed to send children of " .. serviceName)
							return nil
						end
						task.wait() -- Yield between top-level children
					end

					print(serviceName .. " complete")
					print("")
				else
					-- Send service as single chunk
					print("Sending " .. serviceName .. " (" .. math.floor(s.size/1024) .. "KB)...")
					local sent = sendServiceChunk(sessionId, serviceName, s.data)
					if not sent then
						warn("Failed to send service: " .. serviceName)
						return nil
					end
				end

				task.wait() -- Yield between services
			end

			-- Complete the session
			print("")
			print("Completing sync session...")
			local completeSuccess, filesWritten = completeChunkedSession(sessionId)

			if completeSuccess then
				local totalTime = tick() - syncProgress.startTime
				print("")
				print("========================================")
				print("Chunked sync complete!")
				print("   Chunks sent: " .. syncProgress.sentChunks .. "/" .. syncProgress.totalChunks)
				print("   Files written: " .. filesWritten)
				print("   Total time: " .. formatTime(totalTime))
				print("========================================")
				return true
			else
				warn("Failed to complete chunked sync")
				return nil
			end
		else
			-- Small game - use single request sync
			print("")
			print("Using single-request sync...")

			local gameData = {
				ClassName = "DataModel",
				Name = "Game",
				Services = {}
			}

			for _, s in ipairs(serializedServices) do
				table.insert(gameData.Services, s.data)
			end

			local encodeOk, jsonData = pcall(function()
				return HttpService:JSONEncode(gameData)
			end)
			if not encodeOk then
				warn("Failed to JSON-encode full game payload: " .. tostring(jsonData))
				local diag = diagnoseJsonError(gameData, "gameData")
				if diag then
					warn("   Offending field: " .. diag)
				end
				return nil
			end
			print("Sending data to server...")
			local syncSuccess, syncResponse = sendToServer(jsonData)

			if syncSuccess then
				print("Server sync complete!")
			else
				warn("Server sync failed")
			end

			return jsonData
		end
	end)

	if not success then
		warn("Error reading game services:", result)
		warn("========================================")
		warn("SYNC FAILED")
		warn("========================================")
		warn("An error occurred during sync.")
		warn("Check the output above for details.")
		warn("========================================")
	elseif result == nil then
		warn("========================================")
		warn("SYNC FAILED")
		warn("========================================")
		warn("A chunk failed to send to the server.")
		warn("The server may be unreachable or crashed.")
		warn("Please check the server is running and try again.")
		warn("========================================")
	else
		lastFullSyncTime = tick()
		print("Successfully read all game services!")
	end

	-- Summary of sanitized strings (invalid UTF-8 replaced with placeholder)
	if sanitizeStats.count > 0 then
		warn("========================================")
		warn(string.format("Sanitized %d non-UTF-8 string value(s) during sync.", sanitizeStats.count))
		warn("These fields were replaced with '<binary data: N bytes>' placeholders")
		warn("so JSON encoding could succeed. Locations:")
		for _, ex in ipairs(sanitizeStats.examples) do
			warn("   " .. ex)
		end
		if sanitizeStats.count > #sanitizeStats.examples then
			warn(string.format("   ... and %d more", sanitizeStats.count - #sanitizeStats.examples))
		end
		warn("========================================")
	end
end

-- Disable bidirectional mode (forward declaration for use by other mode functions)
local disableBidirectional

-- Enable "Prioritize Studio" mode
local function enablePrioritizeStudio()
	if versionMismatch then
		warn("Cannot enable Prioritize Studio mode: Version mismatch detected")
		return
	end

	if currentMode == SYNC_MODE.PRIORITIZE_STUDIO then
		print("Already in Prioritize Studio mode")
		return
	end

	-- Disable other modes first
	if currentMode == SYNC_MODE.PRIORITIZE_SERVER then
		stopPolling()
	elseif currentMode == SYNC_MODE.BIDIRECTIONAL then
		StudioWatcher.stop()
		stopPolling()
	end

	currentMode = SYNC_MODE.PRIORITIZE_STUDIO
	print("Prioritize Studio mode enabled")
	print("   Studio is now the source of truth")
	print("   Changes in Studio will be sent to the file system")

	-- Do an initial full sync (skip if a full sync was done very recently)
	local timeSinceLastSync = tick() - lastFullSyncTime
	if timeSinceLastSync < RECENT_SYNC_THRESHOLD then
		print(string.format("Skipping initial sync (full sync was done %.0fs ago)", timeSinceLastSync))
	else
		readAllServices()
	end

	-- Start watching for Studio changes
	StudioWatcher.start()
end

-- Disable "Prioritize Studio" mode
local function disablePrioritizeStudio()
	if currentMode ~= SYNC_MODE.PRIORITIZE_STUDIO then
		return
	end

	StudioWatcher.stop()
	currentMode = SYNC_MODE.NONE
	print("Prioritize Studio mode disabled")
end

-- Enable "Prioritize Server" mode
local function enablePrioritizeServer()
	if versionMismatch then
		warn("Cannot enable Prioritize Server mode: Version mismatch detected")
		return
	end

	if currentMode == SYNC_MODE.PRIORITIZE_SERVER then
		print("Already in Prioritize Server mode")
		return
	end

	-- Disable other modes first
	if currentMode == SYNC_MODE.PRIORITIZE_STUDIO then
		StudioWatcher.stop()
	elseif currentMode == SYNC_MODE.BIDIRECTIONAL then
		StudioWatcher.stop()
		stopPolling()
	end

	currentMode = SYNC_MODE.PRIORITIZE_SERVER
	print("Prioritize Server mode enabled")
	print("   File system is now the source of truth")
	print("   Changes in files will be applied to Studio")

	-- Start polling for file changes
	startPolling()
end

-- Disable "Prioritize Server" mode
local function disablePrioritizeServer()
	if currentMode ~= SYNC_MODE.PRIORITIZE_SERVER then
		return
	end

	stopPolling()
	currentMode = SYNC_MODE.NONE
	print("Prioritize Server mode disabled")
end

-- Enable "Bidirectional" mode
local function enableBidirectional()
	if versionMismatch then
		warn("Cannot enable Bidirectional mode: Version mismatch detected")
		return
	end

	if currentMode == SYNC_MODE.BIDIRECTIONAL then
		print("Already in Bidirectional mode")
		return
	end

	-- Disable other modes first
	if currentMode == SYNC_MODE.PRIORITIZE_STUDIO then
		StudioWatcher.stop()
	elseif currentMode == SYNC_MODE.PRIORITIZE_SERVER then
		stopPolling()
	end

	currentMode = SYNC_MODE.BIDIRECTIONAL
	print("Bidirectional sync enabled")
	print("   Changes sync in BOTH directions simultaneously")
	print("   Ctrl+Z in Studio to undo file-system changes")

	-- Do initial full sync (Studio -> FS) to establish baseline
	-- Skip if a full sync was done very recently to avoid redundant 5-minute syncs
	local timeSinceLastSync = tick() - lastFullSyncTime
	if timeSinceLastSync < RECENT_SYNC_THRESHOLD then
		print(string.format("Skipping initial sync (full sync was done %.0fs ago)", timeSinceLastSync))
	else
		readAllServices()
	end

	-- Start both directions
	StudioWatcher.start()
	startPolling()
end

-- Disable "Bidirectional" mode
disableBidirectional = function()
	if currentMode ~= SYNC_MODE.BIDIRECTIONAL then
		return
	end

	StudioWatcher.stop()
	stopPolling()
	currentMode = SYNC_MODE.NONE
	print("Bidirectional sync disabled")
end

-- State for full sync confirmation
local fullSyncClickCount = 0
local lastFullSyncClick = 0

-- Function to perform full sync with double-click confirmation
local function performFullSync()
	if versionMismatch then
		warn("Cannot perform Full Sync: Version mismatch detected")
		return
	end

	local currentTime = tick()

	-- Reset if more than 3 seconds have passed
	if currentTime - lastFullSyncClick > 3 then
		fullSyncClickCount = 0
	end

	lastFullSyncClick = currentTime
	fullSyncClickCount = fullSyncClickCount + 1

	if fullSyncClickCount == 1 then
		print("========================================")
		print("FULL SYNC WARNING")
		print("========================================")
		print("This will OVERWRITE all files on the server!")
		print("Any unsynced changes will be PERMANENTLY LOST!")
		print("")
		print("STRONGLY RECOMMENDED: Commit to Git first!")
		print("")
		print("Click 'Full Sync' button AGAIN within 3 seconds to confirm")
		print("========================================")
	elseif fullSyncClickCount >= 2 then
		print("Starting Full Sync...")
		fullSyncClickCount = 0
		readAllServices()
		print("Full Sync complete!")
	end
end

-- Create toolbar and buttons
local toolbar = plugin:CreateToolbar("RtVS Sync")

local prioritizeStudioButton = toolbar:CreateButton(
	"Prioritize Studio",
	"Studio → Files: Studio is the source of truth, changes sync to files",
	"rbxassetid://4458901886"
)

local prioritizeServerButton = toolbar:CreateButton(
	"Prioritize Server",
	"Files → Studio: Files are the source of truth, changes sync to Studio",
	"rbxassetid://4458901886"
)

local bidirectionalButton = toolbar:CreateButton(
	"Bidirectional",
	"Two-way sync: changes in Studio AND files sync simultaneously",
	"rbxassetid://4458901886"
)

local fullSyncButton = toolbar:CreateButton(
	"Full Sync",
	"WARNING: Overwrite all server files with current Studio state (use with caution!)",
	"rbxassetid://4458901886"
)

local undoSyncButton = toolbar:CreateButton(
	"Undo Last Sync",
	"Undo the last batch of file changes applied to Studio (Ctrl+Z)",
	"rbxassetid://4458901886"
)

local applyCommitsButton = toolbar:CreateButton(
	"Apply Commits",
	"Commit Sync: Fetch and apply all pending file commits to Studio",
	"rbxassetid://4458901886"
)

-- Button click handlers
prioritizeStudioButton.Click:Connect(function()
	if currentMode == SYNC_MODE.PRIORITIZE_STUDIO then
		disablePrioritizeStudio()
		prioritizeStudioButton:SetActive(false)
	else
		enablePrioritizeStudio()
		prioritizeStudioButton:SetActive(true)
		prioritizeServerButton:SetActive(false)
		bidirectionalButton:SetActive(false)
	end
end)

prioritizeServerButton.Click:Connect(function()
	if currentMode == SYNC_MODE.PRIORITIZE_SERVER then
		disablePrioritizeServer()
		prioritizeServerButton:SetActive(false)
	else
		enablePrioritizeServer()
		prioritizeServerButton:SetActive(true)
		prioritizeStudioButton:SetActive(false)
		bidirectionalButton:SetActive(false)
	end
end)

bidirectionalButton.Click:Connect(function()
	if currentMode == SYNC_MODE.BIDIRECTIONAL then
		disableBidirectional()
		bidirectionalButton:SetActive(false)
	else
		enableBidirectional()
		bidirectionalButton:SetActive(true)
		prioritizeStudioButton:SetActive(false)
		prioritizeServerButton:SetActive(false)
	end
end)

fullSyncButton.Click:Connect(function()
	performFullSync()
end)

undoSyncButton.Click:Connect(function()
	ChangeHistoryService:Undo()
	print("Undid last sync batch")
end)

applyCommitsButton.Click:Connect(function()
	if versionMismatch then
		warn("Cannot apply commits: Version mismatch detected")
		return
	end

	local success, response = pcall(function()
		return HttpService:GetAsync(SERVER_URL .. "/commits")
	end)

	if not success then
		warn("RtVS: Could not reach server for commits:", response)
		return
	end

	local data = HttpService:JSONDecode(response)
	if not data or not data.commits then
		warn("RtVS: Invalid commits response")
		return
	end

	if #data.commits == 0 then
		print("RtVS: No pending commits")
		return
	end

	print("RtVS: Applying " .. #data.commits .. " commit(s)...")
	ChangeHistoryService:SetWaypoint("RtVS: Before applying commits")

	local applied = 0
	for _, commit in ipairs(data.commits) do
		local applySuccess, err = pcall(function()
			Deserializer.applyChange({
				type = commit.type == "create" and "create" or (commit.type == "delete" and "delete" or "update"),
				path = commit.path,
				content = commit.resolvedContent,
			})
		end)

		if applySuccess then
			applied = applied + 1
		else
			warn("RtVS: Failed to apply commit for " .. commit.path .. ": " .. tostring(err))
		end
	end

	ChangeHistoryService:SetWaypoint("RtVS: Applied " .. applied .. " commit(s)")
	print("RtVS: Applied " .. applied .. "/" .. #data.commits .. " commits (Ctrl+Z to undo)")

	-- Notify server that commits have been applied
	pcall(function()
		HttpService:PostAsync(
			SERVER_URL .. "/commits/applied",
			HttpService:JSONEncode({}),
			Enum.HttpContentType.ApplicationJson
		)
	end)
end)

-- Plugin initialization
print("RtVS Plugin loaded!")
print("Testing server connection...")
if testConnection() then
	print("TIP: Use 'Bidirectional' for two-way real-time sync")
	print("TIP: Use 'Prioritize Studio' to make Studio the source of truth")
	print("TIP: Use 'Prioritize Server' to make files the source of truth")
	print("TIP: Use 'Undo Last Sync' or Ctrl+Z to rollback file changes")
end
