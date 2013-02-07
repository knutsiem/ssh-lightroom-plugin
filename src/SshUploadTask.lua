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
			local encodedIdentityFilePath = encodeForShell(settings["identity"])
			local escapedCommand = shellCommand(remoteCommand, unpack(arg))
			return execute("ssh -i \"" .. encodedIdentityFilePath .. "\" " .. settings["user"] .. "@" .. settings["host"] .. " '" .. escapedCommand ..  "'")
		end,

		scp = function (source, destination)
			local encodedIdentityFilePath = encodeForShell(settings["identity"])
			local encodedSource = encodeForShell(source)
			local encodedDestination = encodeForShell(destination)
			return execute("scp -i \"" .. encodedIdentityFilePath .. "\" \"" .. encodedSource .. "\" " .. settings["user"] .. "@" .. settings["host"] .. ":'\"" .. encodedDestination .. "\"'")
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
	local progressScope = exportContext:configureProgress {	title = "Uploading photo(s) to " .. exportContext.propertyTable["host"] .. " over SSH" }
	local sshSupport = SshSupport(exportContext.propertyTable)
	local collectionName = exportContext.publishedCollectionInfo["name"]
	local collectionRemoteId = collectionName
	local parents = {}
	do
		local container = exportContext.publishedCollection
		while container:getParent() do
			local parent = container:getParent()
			table.insert(parents, 1, { collectionSet = parent, remoteIdSegment = parent:getName() })
			collectionRemoteId = parents[1].remoteIdSegment .. "/" .. collectionRemoteId
			container = parent
		end
	end
	local collectionPath = sshSupport.remotePath(collectionRemoteId)
	if not sshSupport.ssh('mkdir -p "%s"', collectionPath) then
		error("Remote folder creation failed for collection " .. collectionName	.. ". Consult the Lightroom log for details.")
	end
	exportContext.publishService.catalog:withWriteAccessDo("Update remote ID of published collection and its photos", function(context)
			local accumulatedRemoteId
			for i, parent in ipairs(parents) do
				if accumulatedRemoteId then
					accumulatedRemoteId = accumulatedRemoteId .. "/" .. parent.remoteIdSegment
				else
					accumulatedRemoteId = parent.remoteIdSegment
				end
				logger:debug("Set remoteId of " .. parent.collectionSet:getName() .. " to " .. accumulatedRemoteId)
				parent.collectionSet:setRemoteId(accumulatedRemoteId)
			end
	end)
	exportContext.exportSession:recordRemoteCollectionId(collectionRemoteId)
	for i, rendition in exportContext:renditions { stopIfCanceled = true } do
		local renderSuccess, pathOrMessage = rendition:waitForRender()
		if progressScope:isCanceled() then break end
		if renderSuccess then
			local photoRemoteId = collectionRemoteId .. "/" .. findRemoteFilename(rendition.photo)
			local photoPath = sshSupport.remotePath(photoRemoteId)
			local alreadyPublishedPhoto = findAlreadyPublishedPhoto(rendition.photo, exportContext.publishedCollection)
			if alreadyPublishedPhoto then
				local linkTarget = sshSupport.remotePath(alreadyPublishedPhoto:getRemoteId())
				if sshSupport.ssh('ln -f "%s" "%s"', linkTarget, collectionPath) then
					rendition:recordPublishedPhotoId(photoRemoteId)
				else
					rendition:uploadFailed "Remote link creation failure"
				end
			else
				if sshSupport.ssh('rm -f "%s"', photoPath) then
					if sshSupport.scp(rendition.destinationPath, photoPath) then
						rendition:recordPublishedPhotoId(photoRemoteId)
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
	if not sshSupport.ssh('rm -r "%s"', remoteCollectionPath) then
		error("Failed to delete published collection '" .. info.name .. "' from remote service.")
	end
end

-- Recursively update remote ID prefixes on given container(s) (collection sets and collections) and contained photos
local function updateRemoteIds (containers, oldPrefix, newPrefix)
	if #containers == 0 then return end
	local container = table.remove(containers, 1)
	if container:getRemoteId() then
		container:setRemoteId(container:getRemoteId():gsub(oldPrefix, newPrefix, 1))
		if container.getChildren then
			for _, child in ipairs(container:getChildren()) do table.insert(containers, 1, child) end
		end
		if container.getPublishedPhotos then
			for _, publishedPhoto in ipairs(container:getPublishedPhotos()) do
				publishedPhoto:setRemoteId(publishedPhoto:getRemoteId():gsub(oldPrefix, newPrefix , 1))
			end
		end
	end
	updateRemoteIds(containers, oldPrefix, newPrefix)
end

function SshUploadTask.renamePublishedCollection( publishSettings, info )
	if not info.remoteId then return end
	local sshSupport = SshSupport(publishSettings)
	local oldRemoteId = info.remoteId
	local newRemoteId = info.name
	if info.parents and #info.parents > 0 then
		newRemoteId = info.parents[#info.parents].remoteCollectionId .. "/" .. newRemoteId
	end
	local remoteSourcePath = sshSupport.remotePath(oldRemoteId)
	local remoteDestinationPath = sshSupport.remotePath(newRemoteId)
	if not sshSupport.ssh('rm -rf "%s" && mv "%s" "%s"', remoteDestinationPath, remoteSourcePath, remoteDestinationPath) then
		error("Failed to rename published collection '" .. info.publishedCollection:getName() .. "' to '" .. info.name
				.. "' in remote service.")
	end
	info.publishService.catalog:withWriteAccessDo("Update remote ID of published collection and its photos", function(context)
			updateRemoteIds({ info.publishedCollection }, oldRemoteId, newRemoteId)
	end)
end

function SshUploadTask.reparentPublishedCollection (publishSettings, info)
	if not info.remoteId then return end
	local sshSupport = SshSupport(publishSettings)
	local parentsAndRemoteIds = {}
	for i, parentInfo in ipairs(info.parents) do
		local remoteId
		if parentInfo.remoteCollectionId then
			remoteId = parentInfo.remoteCollectionId
		elseif i > 1 then
			remoteId = parentsAndRemoteIds[i-1].remoteId .. "/" .. parentInfo.name
		else
			remoteId = parentInfo.name
		end
		table.insert(parentsAndRemoteIds, { parentInfo = parentInfo, remoteId =  remoteId })
	end
	local oldRemoteId = info.remoteId
	local sourcePath = sshSupport.remotePath(oldRemoteId)
	local gotParent = info.parents and #info.parents > 0
	local destinationDirPath = sshSupport.remotePath(gotParent and parentsAndRemoteIds[#parentsAndRemoteIds].remoteId or ".")
	if not sshSupport.ssh('mkdir -p "%s" && mv -f "%s" "%s"', destinationDirPath, sourcePath, destinationDirPath) then
		local hadParent = info.publishedCollection:getParent()
		local oldParentDescription = hadParent and ("'" .. info.publishedCollection:getParent():getName() .. "'") or "top level"
		local newParentDescription = gotParent and ("'" .. info.parents[#info.parents].name .. "'") or "top level"
		error(string.format("Failed to reparent '%s' from %s to %s", info.name, oldParentDescription, newParentDescription))
	end
	info.publishService.catalog:withWriteAccessDo("Update remote ID of parent collection sets", function(context)
			for _, parentAndRemoteId in ipairs(parentsAndRemoteIds) do
				local parentCollectionSet = info.publishService.catalog:getPublishedCollectionByLocalIdentifier(
						parentAndRemoteId.parentInfo.localCollectionId)
				parentCollectionSet:setRemoteId(parentAndRemoteId.remoteId)
			end
	end)
	info.publishService.catalog:withWriteAccessDo("Update remote ID of published collection and its photos", function(context)
			local newRemoteId = info.name
			if gotParent then
				newRemoteId = parentsAndRemoteIds[#parentsAndRemoteIds].remoteId .. "/" .. newRemoteId
			end
			updateRemoteIds({ info.publishedCollection }, oldRemoteId, newRemoteId)
	end)
end

function SshUploadTask.validatePublishedCollectionName( proposedName )
	return not proposedName:find("/") and not proposedName:find("\0")
end