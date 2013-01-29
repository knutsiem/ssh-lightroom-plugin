local LrTasks = import "LrTasks"
local exec = LrTasks.execute
local LrPathUtils = import "LrPathUtils"
local LrLogger = import 'LrLogger'
local logger = LrLogger('sshUploadLogger')
logger:enable("print")

SshUploadTask = {}

-- Encode the given string for double-quoted use in a remote Unix-like shell
local function encodeForShell(subject)
	return subject:gsub("%$", "\\%$"):gsub("`", "\\`"):gsub("\"", "\\\""):gsub("\\", "\\\\")
end

local function SshSupport(settings)
	return {
		sshCmd = function (remoteCommand)
			return "ssh -i " .. settings["identity"] .. " " .. settings["user"] .. "@" .. settings["host"] .. " '" .. remoteCommand ..  "'"
		end,

		scpCmd = function (source, destination)
			return "scp -i " .. settings["identity"] .. " " .. source .. " " .. settings["user"] .. "@" .. settings["host"] .. ":'\"" .. destination .. "\"'"
		end,

		remotePath = function (path)
			local baseDir = settings["destination_path"]
			if baseDir and baseDir:len() > 0 then
				return baseDir .. "/" .. path
			else
				return path
			end
		end
	}
end

function SshUploadTask.processRenderedPhotos(functionContext, exportContext)
	logger:debugf("Exporting/publishing %s photos in collection '%s'",
			exportContext.exportSession:countRenditions(), exportContext.publishedCollectionInfo["name"])
	local progressScope = exportContext:configureProgress {	title = "Uploading photo(s) to " .. exportContext.propertyTable["host"] .. " over SSH" }
	local sshSupport = SshSupport(exportContext.propertyTable)
	local collectionPath = sshSupport.remotePath(exportContext.publishedCollectionInfo["name"])
	local sshMkdirStatus = exec(sshSupport.sshCmd(string.format("mkdir -p \"%s\"", encodeForShell(collectionPath))))
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
			local remoteFilename = rendition.photo:getFormattedMetadata("fileName")
			if rendition.photo:getRawMetadata("isVirtualCopy") then
				local copyname = rendition.photo:getFormattedMetadata("copyName")
				remoteFilename = LrPathUtils.addExtension(LrPathUtils.removeExtension(remoteFilename) .. "_" .. copyname,
					LrPathUtils.extension(remoteFilename))
			end
			if alreadyPublishedPhoto then
				local linkTarget = sshSupport.remotePath(alreadyPublishedPhoto:getRemoteId())
				local sshLnCommand = sshSupport.sshCmd(string.format("ln -f \"%s\" \"%s\"", encodeForShell(linkTarget), encodeForShell(collectionPath)))
				logger:debugf("Photo %s has already been published. Linking to it: %s",
						rendition.photo.localIdentifier, sshLnCommand)
				local sshLnStatus = exec(sshLnCommand)
				if sshLnStatus ~= 0 then
					rendition:uploadFailed("Transfer (link) failure, ssh exit status was " .. sshLnStatus)
					break
				end
			else
				local sshRmCommand = sshSupport.sshCmd(string.format("rm -f \"%s\"", encodeForShell(collectionPath .. "/" .. remoteFilename)))
				logger:debugf("Deleting photo %s before uploading to break hardlink: %s", rendition.photo.localIdentifier, sshRmCommand)
				local sshRmStatus = exec(sshRmCommand)
				if sshRmStatus ~= 0 then
					rendition:uploadFailed("Transfer (copy) failure. Tried to remove target file if it existed, but failed. ssh exit status was " .. sshRmStatus)
					break
				end
				local scpCommand = sshSupport.scpCmd(rendition.destinationPath, encodeForShell(collectionPath .. "/" .. remoteFilename ))
				logger:debugf("Uploading photo %s: %s", rendition.photo.localIdentifier, scpCommand)
				local scpStatus = exec(scpCommand)
				if scpStatus ~= 0 then
					rendition:uploadFailed("Transfer (copy) failure, scp exit status was " .. scpStatus)
					break
				end
			end

			rendition:recordPublishedPhotoId(exportContext.publishedCollectionInfo["name"] .. "/" .. remoteFilename)
		else
			-- render failure
			rendition:uploadFailed(pathOrMessage)
		end
	end
	progressScope:done()
end

function SshUploadTask.deletePhotosFromPublishedCollection( publishSettings, arrayOfPhotoIds, deletedCallback, localCollectionId )
	local sshSupport = SshSupport(publishSettings)
	for i, remotePhotoId in ipairs(arrayOfPhotoIds) do
		local remotePhotoPath = sshSupport.remotePath(remotePhotoId)
		local command = sshSupport.sshCmd(string.format("rm -f \"%s\"", encodeForShell(remotePhotoPath)))
		logger:debugf("Deleting photo with remote ID %s from collection %s: %s", remotePhotoId, localCollectionId, command)
		local status = exec(command)
		if status ~= 0 then
			logger:errorf("Could not delete photo with remote ID %s from remote host using %q. Returned status code: %q",
					remotePhotoId, command, status)
			error("Failed to delete published photo with remote ID '".. remotePhotoId .. "' from remote service.")
		end
		deletedCallback(remotePhotoId)
	end
end

function SshUploadTask.deletePublishedCollection (publishSettings, info)
	if not info.remoteId then return end
	local sshSupport = SshSupport(publishSettings)
	local remoteCollectionPath = sshSupport.remotePath(info.remoteId)
	local command = sshSupport.sshCmd(string.format("rm -r \"%s\"", encodeForShell(remoteCollectionPath)))
	logger:debugf("Deleting published collection %q: %s", info.name, command)
	local status = exec(command)
	if status ~= 0 then
		logger:errorf("Could not delete published collection %q from remote host using %q. Returned status code: %q",
				info.name, command, status)
		error("Failed to delete published collection '" .. info.name .. "' from remote service.")
	end
end

function SshUploadTask.renamePublishedCollection( publishSettings, info )
	if not info.remoteId then return end
	local sshSupport = SshSupport(publishSettings)
	local remoteSourcePath = sshSupport.remotePath(info.remoteId)
	local remoteDestinationPath = sshSupport.remotePath(info.name)
	local command = sshSupport.sshCmd(string.format("rm -rf \"%s\" && mv \"%s\" \"%s\"",
			encodeForShell(remoteDestinationPath), encodeForShell(remoteSourcePath), encodeForShell(remoteDestinationPath)))
	logger:debugf("Renaming published collection %q to %q: %s", info.publishedCollection:getName(), info.name, command)
	local status = exec(command)
	if status ~= 0 then
		logger:errorf("Could not rename published collection %q to %q using %q. Returned status code: %q",
				info.publishedCollection:getName(), command, status)
		error("Failed to rename published collection '" .. info.publishedCollection:getName() .. "' to '" .. info.name
				.. "' in remote service.")
	end
	info.publishService.catalog:withWriteAccessDo("Update remote ID of published collection and its photos", function(context)
			info.publishedCollection:setRemoteId(info.name)
			for _, publishedPhoto in ipairs(info.publishedCollection:getPublishedPhotos()) do
				publishedPhoto:setRemoteId(publishedPhoto:getRemoteId():gsub("[^/]+", info.name , 1))
			end
	end)
end

function SshUploadTask.validatePublishedCollectionName( proposedName )
	return not proposedName:find("/") and not proposedName:find("\0")
end