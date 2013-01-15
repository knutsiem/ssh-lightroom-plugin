local LrTasks = import "LrTasks"
local LrPathUtils = import "LrPathUtils"
local LrLogger = import 'LrLogger'
local logger = LrLogger('sshUploadLogger')
logger:enable("print")

SshUploadTask = {}

local function remoteCollectionPath(path, dir)
	if path then
		if path == "" then return dir else return path .. "/" .. dir end
	else
		return dir
	end
end

function SshUploadTask.processRenderedPhotos(functionContext, exportContext)
	logger:debugf("Exporting/publishing collection %q with %s photos",
			exportContext.publishedCollectionInfo["name"], exportContext.exportSession:countRenditions())
	local progressScope = exportContext:configureProgress {	title = "Uploading photo(s) to " .. exportContext.propertyTable["host"] .. " over SSH" }
	local identityKey = exportContext.propertyTable["identity"]
	local sshTarget = exportContext.propertyTable["user"] .. "@" .. exportContext.propertyTable["host"]
	local collectionPath = remoteCollectionPath(exportContext.propertyTable["destination_path"], exportContext.publishedCollectionInfo["name"])
	local sshMkdirStatus = LrTasks.execute("ssh -i " .. identityKey .. " " .. sshTarget .. " 'mkdir -p \"" .. collectionPath .. "\"'")
	if sshMkdirStatus == 0 then
		exportContext.exportSession:recordRemoteCollectionId(exportContext.publishedCollectionInfo["name"])
	else
		error("Remote folder creation failed for collection " .. exportContext.publishedCollectionInfo["name"]
				.. ". ssh exit status was '" .. sshMkdirStatus .. "'. Consult the Lightroom log for details.")
	end
	for i, rendition in exportContext:renditions { stopIfCanceled = true } do
		local success, pathOrMessage = rendition:waitForRender()
		if progressScope:isCanceled() then break end
		if success then
			local firstContainingCollection = rendition.photo:getContainedPublishedCollections()[1]
			if firstContainingCollection and firstContainingCollection ~= exportContext.publishedCollection then
				-- Assuming that the reported published collections containing this photo appear in the order they are
				-- published if multiple collections or a set is selected for publishing. 
				-- Also assuming that an already published rendition of a photo (in another published collection) will
				-- share its remote filename with the current rendition of the same photo as they are processed by the
				-- same publish service configuration
				local linkTarget = remoteCollectionPath(exportContext.propertyTable["destination_path"], firstContainingCollection:getName()) .. "/" .. LrPathUtils.leafName(rendition.destinationPath)
				local sshLnCommand = "ssh -i " .. identityKey .. " " .. sshTarget .. " 'ln -f \"" .. linkTarget .. "\" \"" .. collectionPath .. "\"'"
				logger:debugf("Photo %s has already been published. Linking to it: %s",
						rendition.photo.localIdentifier, sshLnCommand)
				local sshLnStatus = LrTasks.execute(sshLnCommand)
				if (sshLnStatus ~= 0) then
					rendition:uploadFailed("Transfer (link) failure, ssh exit status was " .. sshLnStatus)
					break
				end
			else
				local scpCommand = "scp -i " .. identityKey .. " " .. rendition.destinationPath .. " " .. sshTarget .. ":'\"" .. collectionPath .. "\"'"
				logger:debugf("Uploading photo %s: %s", rendition.photo.localIdentifier, scpCommand)
				local scpStatus = LrTasks.execute(scpCommand)
				if (scpStatus ~= 0) then
					rendition:uploadFailed("Transfer (copy) failure, scp exit status was " .. scpStatus)
					break
				end
			end

			rendition:recordPublishedPhotoId(exportContext.publishedCollectionInfo["name"] .. "/" .. LrPathUtils.leafName(rendition.destinationPath))
		else
			-- render failure
			rendition:uploadFailed(pathOrMessage)
		end
	end
	progressScope:done()
end

function SshUploadTask.deletePhotosFromPublishedCollection( publishSettings, arrayOfPhotoIds, deletedCallback, localCollectionId )
	local identityKey = publishSettings["identity"]
	local sshTarget = publishSettings["user"] .. "@" .. publishSettings["host"]
	for i, remotePhotoId in ipairs(arrayOfPhotoIds) do
		local remotePhotoPath = remoteCollectionPath(publishSettings["destination_path"], remotePhotoId)
		local sshRmCommand = "ssh -i " .. identityKey .. " " .. sshTarget .. " 'rm \"" .. remotePhotoPath .. "\"'"
		logger:debugf("Deleting photo with remoteId %s from collection %s: %s", remotePhotoId, localCollectionId, sshRmCommand)
		local sshRmStatus = LrTasks.execute(sshRmCommand)
		if (sshRmStatus ~= 0) then
			logger:errorf("Could not delete photo with remote ID %s from remote host using %q. Returned status code: %q",
					remotePhotoId, sshRmCommand)
		end
		deletedCallback(remotePhotoId)
	end
end