require "SshUploadTask"
require "SshUploadServiceProviderDialogSections"

return {
	supportsIncrementalPublish = true,
	startDialog = nil,
	sectionsForTopOfDialog = SshUploadServiceProviderDialogSections.topSections,
	hideSections = { 'exportLocation' },
	allowFileFormats = nil,
	allowColorSpaces = nil,
	exportPresetFields = {
		{ key = 'host', default = nil },
		{ key = 'user', default = nil },
		{ key = 'identity', default = nil },
		{ key = 'destination_path', default = nil }
	},
	processRenderedPhotos = SshUploadTask.processRenderedPhotos,
	deletePhotosFromPublishedCollection =  SshUploadTask.deletePhotosFromPublishedCollection,
	deletePublishedCollection = SshUploadTask.deletePublishedCollection,
	renamePublishedCollection = SshUploadTask.renamePublishedCollection,
}
