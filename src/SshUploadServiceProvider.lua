require "SshUploadTask"
require "SshUploadServiceProviderDialogSections"

return {
	hideSections = { 'exportLocation' },
	allowFileFormats = nil,
	allowColorSpaces = nil,
	exportPresetFields = {
		{ key = 'host', default = nil },
		{ key = 'user', default = nil },
		{ key = 'identity', default = nil },
		{ key = 'destination_path', default = nil }
	},
	startDialog = nil,
	sectionsForTopOfDialog = SshUploadServiceProviderDialogSections.topSections,
	processRenderedPhotos = SshUploadTask.processRenderedPhotos,
	supportsIncrementalPublish = true
}
