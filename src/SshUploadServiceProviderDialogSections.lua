local LrView = import "LrView"

SshUploadServiceProviderDialogSections = {}

function SshUploadServiceProviderDialogSections.topSections (viewFactory, propertyTable)
	return {
		{
			title = "SSH connection",
			synopsis = nil,
			viewFactory:static_text {
					title = "User",
			},
			viewFactory:edit_field {
				value = LrView.bind "user"
			},
			viewFactory:static_text {
					title = "Target host",
			},
			viewFactory:edit_field {
				value = LrView.bind "host"
			},
			viewFactory:static_text {
					title = "Identity file",
			},
			viewFactory:edit_field {
				value = LrView.bind "identity"
			},
			viewFactory:static_text {
					title = "Destination path",
			},
			viewFactory:edit_field {
				value = LrView.bind "destination_path"
			}
		}
	}
end