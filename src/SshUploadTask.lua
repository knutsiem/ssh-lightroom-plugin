local LrTasks = import "LrTasks"
local LrPathUtils = import "LrPathUtils"
local LrLogger = import 'LrLogger'
local logger = LrLogger('sshUploadLogger')
logger:enable("print")

SshUploadTask = {}

-- Encode the given string for double-quoted use in a remote Unix-like shell
local function encodeForShell(subject)
	return subject:gsub("%$", "\\%$"):gsub("`", "\\`"):gsub("\"", "\\\""):gsub("\\", "\\\\")
end

local function sshCmd(settings, remoteCommand)
	return "ssh -i " .. settings["identity"] .. " " .. settings["user"] .. "@" .. settings["host"] .. " '" .. remoteCommand ..  "'"
end

local function scpCmd(settings, source, destination)
	return "scp -i " .. settings["identity"] .. " " .. source .. " " .. settings["user"] .. "@" .. settings["host"] .. ":'\"" .. destination .. "\"'"
end

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
	local collectionPath = remoteCollectionPath(exportContext.propertyTable["destination_path"], exportContext.publishedCollectionInfo["name"])
	local sshMkdirStatus = LrTasks.execute(sshCmd(exportContext.propertyTable, string.format("mkdir -p \"%s\"", encodeForShell(collectionPath))))
	if sshMkdirStatus == 0 then
		exportContext.exportSession:recordRemoteCollectionId(exportContext.publishedCollectionInfo["name"])
	else
		error("Remote folder creation failed for collection " .. exportContext.publishedCollectionInfo["name"]
				.. ". ssh exit status was '" .. sshMkdirStatus .. "'. Consult the Lightroom log for details.")
	end
	for i, rendition in exportContext:renditions { stopIfCanceled = true } do
		local renderSuccess, pathOrMessage = rendition:waitForRender()
		if progressScope:isCanceled() then break end
		if renderSuccess then
			-- Loop over the published collections that contains this photo to find a non-modified/up-to-date
			-- published-photo to link to on the remote side. If none exist, upload.
			local alreadyPublishedPhoto = nil
			for _, publishedCollection in ipairs(rendition.photo:getContainedPublishedCollections()) do
				if alreadyPublishedPhoto then break end
				if publishedCollection ~= exportContext.publishedCollection then
					for __, publishedPhoto in ipairs(publishedCollection:getPublishedPhotos()) do
						if publishedPhoto:getPhoto() == rendition.photo and not publishedPhoto:getEditedFlag() then
							alreadyPublishedPhoto = publishedPhoto
							break
						end
					end
				end
			end
			if alreadyPublishedPhoto then
				local linkTarget = remoteCollectionPath(exportContext.propertyTable["destination_path"], alreadyPublishedPhoto:getRemoteId())
				local sshLnCommand = sshCmd(exportContext.propertyTable, string.format("ln -f \"%s\" \"%s\"", encodeForShell(linkTarget), encodeForShell(collectionPath)))
				logger:debugf("Photo %s has already been published. Linking to it: %s",
						rendition.photo.localIdentifier, sshLnCommand)
				local sshLnStatus = LrTasks.execute(sshLnCommand)
				if (sshLnStatus ~= 0) then
					rendition:uploadFailed("Transfer (link) failure, ssh exit status was " .. sshLnStatus)
					break
				end
			else
				local sshRmCommand = sshCmd(exportContext.propertyTable, string.format("rm -f \"%s\"", encodeForShell(collectionPath.."/"..LrPathUtils.leafName(rendition.destinationPath))))
				logger:debugf("Deleting photo %s before uploading to break hardlink: %s", rendition.photo.localIdentifier, sshRmCommand)
				local sshRmStatus = LrTasks.execute(sshRmCommand)
				if sshRmStatus ~= 0 then
					rendition:uploadFailed("Transfer (copy) failure. Tried to remove target file if it existed, but failed. ssh exit status was " .. sshRmStatus)
					break
				end
				local scpCommand = scpCmd(exportContext.propertyTable, rendition.destinationPath, encodeForShell(collectionPath))
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
	for i, remotePhotoId in ipairs(arrayOfPhotoIds) do
		local remotePhotoPath = remoteCollectionPath(publishSettings["destination_path"], remotePhotoId)
		local sshRmCommand = sshCmd(publishSettings, string.format("rm \"%s\"", encodeForShell(remotePhotoPath)))
		logger:debugf("Deleting photo with remote ID %s from collection %s: %s", remotePhotoId, localCollectionId, sshRmCommand)
		local sshRmStatus = LrTasks.execute(sshRmCommand)
		if (sshRmStatus ~= 0) then
			logger:errorf("Could not delete photo with remote ID %s from remote host using %q. Returned status code: %q",
					remotePhotoId, sshRmCommand, sshRmStatus)
			error("Failed to delete published photo with remote ID '".. remotePhotoId .. "' from remote service.")
		end
		deletedCallback(remotePhotoId)
	end
end

function SshUploadTask.deletePublishedCollection (publishSettings, info)
	local remoteCollectionPath = remoteCollectionPath(publishSettings["destination_path"], info.remoteId)
	local sshRmCommand = sshCmd(publishSettings, string.format("rm -r \"%s\"", encodeForShell(remoteCollectionPath)))
	logger:debugf("Deleting published collection %q: %s", info.name, sshRmCommand)
	local sshRmStatus = LrTasks.execute(sshRmCommand)
	if (sshRmStatus ~= 0) then
		logger:errorf("Could not delete published collection %q from remote host using %q. Returned status code: %q",
				info.name, sshRmCommand, sshRmStatus)
		error("Failed to delete published collection '" .. info.name .. "' from remote service.")
	end
end

function SshUploadTask.renamePublishedCollection( publishSettings, info )
	local remoteCollectionSourcePath = remoteCollectionPath(publishSettings["destination_path"], info.remoteId)
	local remoteCollectionDestinationPath = remoteCollectionPath(publishSettings["destination_path"], info.name)
	local sshMvCommand = sshCmd(publishSettings, string.format("rm -rf \"%s\" && mv \"%s\" \"%s\"",
			encodeForShell(remoteCollectionDestinationPath), encodeForShell(remoteCollectionSourcePath), encodeForShell(remoteCollectionDestinationPath)))
	logger:debugf("Renaming published collection %q to %q: %s", info.publishedCollection:getName(), info.name, sshMvCommand)
	local sshMvStatus = LrTasks.execute(sshMvCommand)
	if (sshMvStatus ~= 0) then
		logger:errorf("Could not rename published collection %q to %q using %q. Returned status code: %q",
				info.publishedCollection:getName(), sshMvCommand, sshMvStatus)
		error("Failed to rename published collection '" .. info.publishedCollection:getName() .. "' to '" .. info.name
				.. "' in remote service.")
	end
	info.publishService.catalog:withWriteAccessDo("Update remote ID of published collection and its photos", function(context)
			info.publishedCollection:setRemoteId(info.name)
			for _, publishedPhoto in ipairs(info.publishedCollection:getPublishedPhotos()) do
				publishedPhoto:setRemoteId(string.gsub(publishedPhoto:getRemoteId(), "[^/]+", info.name , 1))
			end
	end)
end