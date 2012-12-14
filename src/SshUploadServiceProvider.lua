require "SshUploadTask"
require "SshUploadServiceProviderDialogSections"

return {
	hideSections = { 'exportLocation' },
	allowFileFormats = nil,
	allowColorSpaces = nil,
	exportPresetFields = {
		{ key = 'host', default = nil },
		{ key = 'user', default = nil },
		{ key = 'identity', default = nil }
	},
	startDialog = nil,
	sectionsForTopOfDialog = SshUploadServiceProviderDialogSections.topSections,
	processRenderedPhotos = SshUploadTask.processRenderedPhotos,
	supportsIncrementalPublish = true
}
