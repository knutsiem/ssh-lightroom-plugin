local LrTasks = import "LrTasks"
local LrPathUtils = import "LrPathUtils"

SshUploadTask = {}

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
				local collectionName = collection:getName()
				local sshMkdirStatus = LrTasks.execute("ssh -i " .. identityKey .. " " .. sshTarget .. " 'mkdir -p \"" .. collectionName .. "\"'")
				if j == 1 then
					local scpStatus = LrTasks.execute("scp -i " .. identityKey .. " " .. rendition.destinationPath .. " " .. sshTarget .. ":'\"" .. collectionName .. "\"'")
					if (scpStatus ~= 0) then
						-- transfer failure
						rendition:uploadFailed("Transfer (copy) failure, scp exit status was " .. scpStatus)
					end
				else
					local sshLnStatus = LrTasks.execute("ssh -i " .. identityKey .. " " .. sshTarget .. " 'ln \"" .. hardlinkTarget .. "\" \"" .. collectionName .. "\"'")
					if (sshLnStatus ~= 0) then
						-- transfer failure
						rendition:uploadFailed("Transfer (hardlink) failure, ssh exit status was " .. sshLnStatus)
					end
				end
				hardlinkTarget = collectionName .. "/" .. LrPathUtils.leafName(rendition.destinationPath)
			end
		else
			-- render failure
			rendition:uploadFailed(pathOrMessage)
		end
	end
	progressScope:done()
end