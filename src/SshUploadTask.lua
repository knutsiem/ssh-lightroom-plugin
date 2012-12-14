local LrTasks = import "LrTasks"
local LrPathUtils = import "LrPathUtils"

SshUploadTask = {}

local function destinationPath(path, dir)
	if path then
		if path == "" then return dir else return path .. "/" .. dir end
	else
		return dir
	end
end

function SshUploadTask.processRenderedPhotos(functionContext, exportContext)
	local progressScope = exportContext:configureProgress {	title = "Uploading photo(s) to " .. exportContext.propertyTable["host"] .. " over SSH" }
	for i, rendition in exportContext:renditions { stopIfCanceled = true } do
		local success, pathOrMessage = rendition:waitForRender()
		if progressScope:isCanceled() then break end
		if success then
			local identityKey = exportContext.propertyTable["identity"]
			local sshTarget = exportContext.propertyTable["user"] .. "@" .. exportContext.propertyTable["host"]
			local hardlinkTarget = nil
			for j, collection in ipairs(rendition.photo:getContainedCollections()) do
				-- todo: what about ""?
				local collectionPath = destinationPath(exportContext.propertyTable["destination_path"], collection:getName())
				local sshMkdirStatus = LrTasks.execute("ssh -i " .. identityKey .. " " .. sshTarget .. " 'mkdir -p \"" .. collectionPath .. "\"'")
				if j == 1 then
					local scpStatus = LrTasks.execute("scp -i " .. identityKey .. " " .. rendition.destinationPath .. " " .. sshTarget .. ":'\"" .. collectionPath .. "\"'")
					if (scpStatus ~= 0) then
						-- transfer failure
						rendition:uploadFailed("Transfer (copy) failure, scp exit status was " .. scpStatus)
					end
				else
					local sshLnStatus = LrTasks.execute("ssh -i " .. identityKey .. " " .. sshTarget .. " 'ln \"" .. hardlinkTarget .. "\" \"" .. collectionPath .. "\"'")
					if (sshLnStatus ~= 0) then
						-- transfer failure
						rendition:uploadFailed("Transfer (hardlink) failure, ssh exit status was " .. sshLnStatus)
					end
				end
				hardlinkTarget = collectionPath .. "/" .. LrPathUtils.leafName(rendition.destinationPath)
			end
		else
			-- render failure
			rendition:uploadFailed(pathOrMessage)
		end
	end
	progressScope:done()
end