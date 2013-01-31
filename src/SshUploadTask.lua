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

local function SshSupport(settings)

	-- Prepares a shell command template with any number of arguments, encoding the arguments for use in double quotes
	local function shellCommand (commandTemplate, ...)
		local encodedArgs = {}
		for i, argument in ipairs(arg) do
			encodedArgs[i] = encodeForShell(argument)
		end
		return commandTemplate:format(unpack(encodedArgs))
	end

	-- Execute command with LrTasks.execute. Log non-zero staus code as error. Return true on success, false on error.
	local function execute (command)
		logger:debug("Executing command: " .. command)
		local status = LrTasks.execute(command)
		if status ~= 0 then
			local errorMessage = string.format("Execution of %s failed with status code %s", command, status)
			logger:error(errorMessage)
			return false
		end
		return true
	end

	return {
		ssh = function(remoteCommand, ...)
			local escapedCommand = shellCommand(remoteCommand, unpack(arg))
			return execute("ssh -i " .. settings["identity"] .. " " .. settings["user"] .. "@" .. settings["host"] .. " '" .. escapedCommand ..  "'")
		end,

		scp = function (source, destination)
			return execute("scp -i " .. settings["identity"] .. " " .. source .. " " .. settings["user"] .. "@" .. settings["host"] .. ":'\"" .. destination .. "\"'")
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

local function findRemoteFilename (photo)
	local remoteFilename = photo:getFormattedMetadata("fileName")
	if photo:getRawMetadata("isVirtualCopy") then
		local copyname = photo:getFormattedMetadata("copyName")
		remoteFilename = LrPathUtils.addExtension(LrPathUtils.removeExtension(remoteFilename) .. "_" .. copyname,
			LrPathUtils.extension(remoteFilename))
	end
	return remoteFilename
end

-- Loop over the published collections that contains this photo to find a non-modified/up-to-date
-- published-photo to link to on the remote side. If none exist, upload.
local function findAlreadyPublishedPhoto (photo, currentPublishedCollection)
	for _, publishedCollection in ipairs(photo:getContainedPublishedCollections()) do
		if publishedCollection ~= currentPublishedCollection then
			for __, publishedPhoto in ipairs(publishedCollection:getPublishedPhotos()) do
				if publishedPhoto:getPhoto() == photo and not publishedPhoto:getEditedFlag() then
					return publishedPhoto
				end
			end
		end
	end
end

function SshUploadTask.processRenderedPhotos(functionContext, exportContext)
	local collectionName = exportContext.publishedCollectionInfo["name"]
	logger:debugf("Exporting/publishing %s photos in collection '%s'",
			exportContext.exportSession:countRenditions(), collectionName)
	local progressScope = exportContext:configureProgress {	title = "Uploading photo(s) to " .. exportContext.propertyTable["host"] .. " over SSH" }
	local sshSupport = SshSupport(exportContext.propertyTable)
	local collectionPath = sshSupport.remotePath(collectionName)
	if not sshSupport.ssh('mkdir -p "%s"', collectionPath) then
		error("Remote folder creation failed for collection " .. collectionName	.. ". Consult the Lightroom log for details.")
	end
	exportContext.exportSession:recordRemoteCollectionId(collectionName)
	for i, rendition in exportContext:renditions { stopIfCanceled = true } do
		local renderSuccess, pathOrMessage = rendition:waitForRender()
		if progressScope:isCanceled() then break end
		if renderSuccess then
			local photo = rendition.photo
			local remoteFilename = findRemoteFilename(photo)
			local alreadyPublishedPhoto = findAlreadyPublishedPhoto(photo, exportContext.publishedCollection)
			if alreadyPublishedPhoto then
				local linkTarget = sshSupport.remotePath(alreadyPublishedPhoto:getRemoteId())
				logger:debugf("Photo %s has already been published. Linking to it...", photo.localIdentifier)
				if sshSupport.ssh('ln -f "%s" "%s"', linkTarget, collectionPath) then
					rendition:recordPublishedPhotoId(collectionName .. "/" .. remoteFilename)
				else
					rendition:uploadFailed "Remote link creation failure"
				end
			else
				logger:debugf("Deleting photo %s before uploading to break hardlink...", photo.localIdentifier)
				if sshSupport.ssh('rm -f "%s"', collectionPath .. "/" .. remoteFilename) then
					logger:debugf("Uploading photo %s...", photo.localIdentifier)
					if sshSupport.scp(rendition.destinationPath, encodeForShell(collectionPath .. "/" .. remoteFilename )) then
						rendition:recordPublishedPhotoId(collectionName .. "/" .. remoteFilename)
					else
						rendition:uploadFailed "Upload failure"
					end
				else
					rendition:uploadFailed "Upload preparation failure when removing potentially existing target file."
				end
			end
		else
			rendition:uploadFailed(pathOrMessage)
		end
	end
	progressScope:done()
end

function SshUploadTask.deletePhotosFromPublishedCollection( publishSettings, arrayOfPhotoIds, deletedCallback, localCollectionId )
	local sshSupport = SshSupport(publishSettings)
	for i, remotePhotoId in ipairs(arrayOfPhotoIds) do
		local remotePhotoPath = sshSupport.remotePath(remotePhotoId)
		logger:debugf("Deleting photo with remote ID %s from collection %s...", remotePhotoId, localCollectionId)
		if not sshSupport.ssh('rm -f "%s"', remotePhotoPath) then
			error("Failed to delete published photo with remote ID '".. remotePhotoId .. "' from remote service.")
		end
		deletedCallback(remotePhotoId)
	end
end

function SshUploadTask.deletePublishedCollection (publishSettings, info)
	if not info.remoteId then return end
	local sshSupport = SshSupport(publishSettings)
	local remoteCollectionPath = sshSupport.remotePath(info.remoteId)
	logger:debugf("Deleting published collection %q...", info.name)
	if not sshSupport.ssh('rm -r "%s"', remoteCollectionPath) then
		error("Failed to delete published collection '" .. info.name .. "' from remote service.")
	end
end

function SshUploadTask.renamePublishedCollection( publishSettings, info )
	if not info.remoteId then return end
	local sshSupport = SshSupport(publishSettings)
	local remoteSourcePath = sshSupport.remotePath(info.remoteId)
	local remoteDestinationPath = sshSupport.remotePath(info.name)
	logger:debugf("Renaming published collection %q to %q...", info.publishedCollection:getName(), info.name)
	if not sshSupport.ssh('rm -rf "%s" && mv "%s" "%s"', remoteDestinationPath, remoteSourcePath, remoteDestinationPath) then
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