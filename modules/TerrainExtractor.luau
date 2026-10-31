--!optimize 2
-- ============================================================
-- NexusCopy — TerrainExtractor Module
-- Extracts full terrain voxel data (materials + occupancy)
-- and serializes it to replayable Luau code for Studio
-- ============================================================

local TerrainExtractor = {}
TerrainExtractor.__index = TerrainExtractor

-- Stats tracking
local stats = {
	totalChunks = 0,
	nonEmptyChunks = 0,
	totalVoxels = 0,
	terrainSize = Vector3.zero,
	extractionTime = 0,
}

-- Stored voxel data for serialization
local storedChunks = {} -- {region, materials, occupancy}

--------------------------------------------------------------
-- Material Enum → Name mapping for serialization
--------------------------------------------------------------
local materialNames = {}
for _, item in ipairs(Enum.Material:GetEnumItems()) do
	materialNames[item.Value] = item.Name
end

--------------------------------------------------------------
-- Check if a chunk is empty (all Air, 0 occupancy)
--------------------------------------------------------------
local function isChunkEmpty(materials, occupancy)
	local airMat = Enum.Material.Air
	for x, xMats in ipairs(materials) do
		for y, yMats in ipairs(xMats) do
			for z, mat in ipairs(yMats) do
				if mat ~= airMat or occupancy[x][y][z] > 0 then
					return false
				end
			end
		end
	end
	return true
end

--------------------------------------------------------------
-- Extract terrain data
--------------------------------------------------------------
--- @param options {onProgress: (number) -> (), chunkSize: number?, resolution: number?}
function TerrainExtractor:Extract(options)
	local opts = options.TerrainOptions or {}
	opts.onProgress = opts.onProgress or options.onProgress
	options = opts
	local chunkSize = options.chunkSize or 16
	local resolution = options.resolution or 4 -- Roblox min resolution
	local onProgress = options.onProgress

	local terrain = workspace.Terrain
	local startTime = os.clock()

	-- Reset state
	storedChunks = {}
	stats = {
		totalChunks = 0,
		nonEmptyChunks = 0,
		totalVoxels = 0,
		terrainSize = Vector3.zero,
		extractionTime = 0,
	}

	-- Get terrain bounds
	-- MaxExtents gives Region3int16, we need to convert to world coords
	local maxRadius = options.maxRadius or options.MaxRadius or 512

	local extents
	local player = game:GetService("Players").LocalPlayer
	local playerPos = player and player.Character
		and player.Character:FindFirstChild("HumanoidRootPart")
		and player.Character.HumanoidRootPart.Position

	-- Use actual used terrain bounds when available, else clamp around player
	local cellOK, cellCount = pcall(function() return terrain:CountCells() end)

	if playerPos then
		extents = {
			min = Vector3.new(
				playerPos.X - maxRadius,
				playerPos.Y - maxRadius,
				playerPos.Z - maxRadius),
			max = Vector3.new(
				playerPos.X + maxRadius,
				playerPos.Y + maxRadius,
				playerPos.Z + maxRadius),
		}
	else
		warn("[NexusCopy/Terrain] No character found, using fallback bounds around origin")
		extents = {
			min = Vector3.new(-maxRadius, -maxRadius, -maxRadius),
			max = Vector3.new(maxRadius, maxRadius, maxRadius),
		}
	end

	if cellOK and (cellCount or 0) == 0 then
		warn("[NexusCopy/Terrain] Terrain is empty, skipping scan")
		stats.extractionTime = 0
		return storedChunks
	end

	local minPos = extents.min
	local maxPos = extents.max
	local size = maxPos - minPos
	local lastLog = os.clock()
	stats.terrainSize = size

	print(string.format("[NexusCopy/Terrain] Bounds: (%d,%d,%d) to (%d,%d,%d)",
		minPos.X, minPos.Y, minPos.Z, maxPos.X, maxPos.Y, maxPos.Z))
	print(string.format("[NexusCopy/Terrain] Size: %dx%dx%d studs", size.X, size.Y, size.Z))

	-- Calculate total chunks
	local chunksX = math.ceil(size.X / (chunkSize * resolution))
	local chunksY = math.ceil(size.Y / (chunkSize * resolution))
	local chunksZ = math.ceil(size.Z / (chunkSize * resolution))
	local totalChunks = chunksX * chunksY * chunksZ
	stats.totalChunks = totalChunks

	print(string.format("[NexusCopy/Terrain] Total chunks to scan: %d (%dx%dx%d)",
		totalChunks, chunksX, chunksY, chunksZ))

	local chunkStep = chunkSize * resolution -- World-space step per chunk
	local processed = 0

	for x = minPos.X, maxPos.X - 1, chunkStep do
		for y = minPos.Y, maxPos.Y - 1, chunkStep do
			for z = minPos.Z, maxPos.Z - 1, chunkStep do
				processed += 1

				local regionMin = Vector3.new(x, y, z)
				local regionMax = Vector3.new(
					math.min(x + chunkStep, maxPos.X),
					math.min(y + chunkStep, maxPos.Y),
					math.min(z + chunkStep, maxPos.Z)
				)

				local region = Region3.new(regionMin, regionMax):ExpandToGrid(resolution)

				-- Read voxels safely
				local readOk, materials, occupancy
				readOk, materials, occupancy = pcall(function()
					return terrain:ReadVoxels(region, resolution)
				end)

				if readOk and materials and #materials > 0 then
					-- Check if chunk has any non-empty voxels
					if not isChunkEmpty(materials, occupancy) then
						stats.nonEmptyChunks += 1

						-- Count voxels in this chunk
						local voxelCount = #materials * #materials[1] * #materials[1][1]
						stats.totalVoxels += voxelCount

						-- Store chunk data
						table.insert(storedChunks, {
							region = region,
							regionMin = regionMin,
							regionMax = regionMax,
							materials = materials,
							occupancy = occupancy,
							resolution = resolution,
						})
					end
				end

				-- Progress callback every chunk so UI moves visibly
				if onProgress then
					onProgress(math.min(processed / totalChunks, 1))
				end

				-- Console heartbeat every 2s so Dev Console shows it's alive
				local now = os.clock()
				if now - lastLog >= 2 then
					lastLog = now
					local pct = processed / totalChunks * 100
					local eta = pct > 0 and (os.clock() - startTime) / pct * (100 - pct) or 0
					print(string.format("[NexusCopy/Terrain] Progress: %d/%d chunks (%.1f%%) — %d non-empty, %d voxels — ETA ~%dm%ds",
						processed, totalChunks, pct, stats.nonEmptyChunks, stats.totalVoxels,
						math.floor(eta / 60), math.floor(eta % 60)))
				end

				-- Yield every chunk to prevent timeout
				task.wait()
			end
		end
	end

	stats.extractionTime = os.clock() - startTime

	if onProgress then onProgress(1) end

	print(string.format("[NexusCopy/Terrain] Done! %d non-empty chunks out of %d total (%.1fs)",
		stats.nonEmptyChunks, stats.totalChunks, stats.extractionTime))

	return storedChunks
end

--------------------------------------------------------------
-- Get extraction stats
--------------------------------------------------------------
function TerrainExtractor:GetStats()
	return stats
end

--------------------------------------------------------------
-- Serialize for replay in Studio
-- Generates Luau code that recreates terrain via WriteVoxels
--------------------------------------------------------------
function TerrainExtractor:SerializeForReplay()
	if #storedChunks == 0 then
		return "-- NexusCopy TerrainExtractor: No terrain data captured\nprint('No terrain to restore')\n"
	end

	local output = {}
	table.insert(output, "-- ============================================================")
	table.insert(output, "-- NexusCopy — Terrain Restore Script")
	table.insert(output, "-- Generated terrain data: " .. stats.nonEmptyChunks .. " chunks")
	table.insert(output, "-- Total voxels: " .. stats.totalVoxels)
	table.insert(output, string.format("-- Terrain size: %dx%dx%d studs",
		stats.terrainSize.X, stats.terrainSize.Y, stats.terrainSize.Z))
	table.insert(output, "-- ============================================================")
	table.insert(output, "")
	table.insert(output, "local terrain = workspace.Terrain")
	table.insert(output, "terrain:Clear()")
	table.insert(output, "")
	table.insert(output, "local M = Enum.Material")
	table.insert(output, string.format("print('[NexusCopy] Restoring terrain: %d chunks...')", #storedChunks))
	table.insert(output, "")

	for i, chunk in ipairs(storedChunks) do
		local res = chunk.resolution
		local rMin = chunk.regionMin
		local rMax = chunk.regionMax

		table.insert(output, string.format("-- Chunk %d/%d", i, #storedChunks))
		table.insert(output, "do")

		-- Serialize materials 3D array
		table.insert(output, "\tlocal materials = {")
		for x, xMats in ipairs(chunk.materials) do
			table.insert(output, "\t\t{")
			for y, yMats in ipairs(xMats) do
				local row = {}
				for z, mat in ipairs(yMats) do
					local name = materialNames[mat.Value] or "Air"
					table.insert(row, "M." .. name)
				end
				table.insert(output, "\t\t\t{" .. table.concat(row, ",") .. "},")
			end
			table.insert(output, "\t\t},")
		end
		table.insert(output, "\t}")

		-- Serialize occupancy 3D array
		table.insert(output, "\tlocal occupancy = {")
		for x, xOcc in ipairs(chunk.occupancy) do
			table.insert(output, "\t\t{")
			for y, yOcc in ipairs(xOcc) do
				local row = {}
				for z, occ in ipairs(yOcc) do
					-- Round to 2 decimal places to save space
					if occ == 0 then
						table.insert(row, "0")
					elseif occ == 1 then
						table.insert(row, "1")
					else
						table.insert(row, string.format("%.2f", occ))
					end
				end
				table.insert(output, "\t\t\t{" .. table.concat(row, ",") .. "},")
			end
			table.insert(output, "\t\t},")
		end
		table.insert(output, "\t}")

		-- WriteVoxels call
		table.insert(output, string.format(
			"\tlocal region = Region3.new(Vector3.new(%g,%g,%g), Vector3.new(%g,%g,%g)):ExpandToGrid(%d)",
			rMin.X, rMin.Y, rMin.Z, rMax.X, rMax.Y, rMax.Z, res))
		table.insert(output, string.format("\tterrain:WriteVoxels(region, %d, materials, occupancy)", res))
		table.insert(output, "end")

		-- Progress print every 50 chunks
		if i % 50 == 0 then
			table.insert(output, string.format("print('[NexusCopy] Terrain: %d/%d chunks done')", i, #storedChunks))
			table.insert(output, "task.wait()")
		end

		table.insert(output, "")
	end

	table.insert(output, string.format("print('[NexusCopy] Terrain restored! %d chunks')", #storedChunks))

	return table.concat(output, "\n")
end

--------------------------------------------------------------
-- Serialize to compact binary-like format (for embedding in .rbxlx)
-- Returns base64-encoded terrain data
--------------------------------------------------------------
function TerrainExtractor:SerializeCompact()
	if #storedChunks == 0 then return nil end

	-- Simple format: JSON-like structure that can be stored as StringValue
	local data = {
		version = 1,
		chunkCount = #storedChunks,
		chunks = {},
	}

	for _, chunk in ipairs(storedChunks) do
		local chunkData = {
			min = { chunk.regionMin.X, chunk.regionMin.Y, chunk.regionMin.Z },
			max = { chunk.regionMax.X, chunk.regionMax.Y, chunk.regionMax.Z },
			res = chunk.resolution,
			materials = {},
			occupancy = {},
		}

		-- Flatten 3D arrays to 1D for compact storage
		for x, xMats in ipairs(chunk.materials) do
			for y, yMats in ipairs(xMats) do
				for z, mat in ipairs(yMats) do
					table.insert(chunkData.materials, mat.Value)
				end
			end
		end

		for x, xOcc in ipairs(chunk.occupancy) do
			for y, yOcc in ipairs(xOcc) do
				for z, occ in ipairs(yOcc) do
					table.insert(chunkData.occupancy, math.floor(occ * 255))
				end
			end
		end

		table.insert(data.chunks, chunkData)
	end

	-- Use HttpService for JSON encoding
	local ok, json = pcall(function()
		return game:GetService("HttpService"):JSONEncode(data)
	end)

	return ok and json or nil
end

return TerrainExtractor
