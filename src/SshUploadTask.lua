local LrTasks = import "LrTasks"
local LrPathUtils = import "LrPathUtils"
local LrLogger = import 'LrLogger'
local logger = LrLogger('sshUploadLogger')
logger:enable("print")

SshUploadTask = {}

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

-- Encode the given string for double-quoted use in a remote Unix-like shell
local function encodeForShell(subject)
	return subject:gsub("%$", "\\%$"):gsub("`", "\\`"):gsub("\"", "\\\""):gsub("\\", "\\\\")
end

-- Prepares a shell command template with any number of arguments, encoding the arguments for use in double quotes
local function shellCommand (commandTemplate, ...)
	local encodedArgs = {}
	for i, argument in ipairs(arg) do
		encodedArgs[i] = encodeForShell(argument)
	end
	return commandTemplate:format(unpack(encodedArgs))
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
	do
		if not execute(sshSupport.sshCmd(shellCommand('mkdir -p "%s"', collectionPath))) then
			error("Remote folder creation failed for collection " .. exportContext.publishedCollectionInfo["name"]
					.. ". Consult the Lightroom log for details.")
		end
		exportContext.exportSession:recordRemoteCollectionId(exportContext.publishedCollectionInfo["name"])
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
				logger:debugf("Photo %s has already been published. Linking to it...", rendition.photo.localIdentifier)
				if not execute(sshSupport.sshCmd(shellCommand('ln -f "%s" "%s"', linkTarget, collectionPath))) then
					rendition:uploadFailed("Transfer (link) failure")
					break
				end
			else
				logger:debugf("Deleting photo %s before uploading to break hardlink...", rendition.photo.localIdentifier)
				if not execute(sshSupport.sshCmd(shellCommand('rm -f "%s"', collectionPath .. "/" .. remoteFilename))) then
					rendition:uploadFailed("Transfer (copy) failure. Tried to remove target file if it existed, but failed.")
					break
				end
				logger:debugf("Uploading photo %s...", rendition.photo.localIdentifier)
				if not execute(sshSupport.scpCmd(rendition.destinationPath, encodeForShell(collectionPath .. "/" .. remoteFilename ))) then
					rendition:uploadFailed("Transfer (copy) failure")
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
		logger:debugf("Deleting photo with remote ID %s from collection %s...", remotePhotoId, localCollectionId)
		if not execute(sshSupport.sshCmd(shellCommand('rm -f "%s"', remotePhotoPath))) then
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
	if not execute(sshSupport.sshCmd(shellCommand('rm -r "%s"', remoteCollectionPath))) then
		error("Failed to delete published collection '" .. info.name .. "' from remote service.")
	end
end

function SshUploadTask.renamePublishedCollection( publishSettings, info )
	if not info.remoteId then return end
	local sshSupport = SshSupport(publishSettings)
	local remoteSourcePath = sshSupport.remotePath(info.remoteId)
	local remoteDestinationPath = sshSupport.remotePath(info.name)
	logger:debugf("Renaming published collection %q to %q...", info.publishedCollection:getName(), info.name)
	if not execute(sshSupport.sshCmd(shellCommand('rm -rf "%s" && mv "%s" "%s"', remoteDestinationPath, remoteSourcePath, remoteDestinationPath))) then
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