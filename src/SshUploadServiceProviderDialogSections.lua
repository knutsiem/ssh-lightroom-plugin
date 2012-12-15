local LrView = import "LrView"

SshUploadServiceProviderDialogSections = {}

function SshUploadServiceProviderDialogSections.topSections (viewFactory, propertyTable)
	return {
		{
			title = "SSH connection",
			synopsis = function (props)
				return props["user"] .. "@" .. props["host"] .. ":" .. props["destination_path"]
			end,
			viewFactory:row {
				spacing = viewFactory:control_spacing(),
				viewFactory:column {
					viewFactory:static_text {
						title = "User",
					},
					viewFactory:edit_field {
						value = LrView.bind "user",
						width_in_chars = 10
					}
				},
				viewFactory:column {
					viewFactory:static_text {
						title = "Target host",
					},
					viewFactory:edit_field {
						value = LrView.bind "host",
						width_in_chars = 10
					}
				},
				viewFactory:column {
					viewFactory:static_text {
						title = "Destination path",
					},
					viewFactory:edit_field {
						value = LrView.bind "destination_path",
						fill = 1
					},
					fill = 1
				}
			},
			viewFactory:spacer {},
			viewFactory:row {
				viewFactory:static_text {
						title = "Identity file",
				},
				viewFactory:edit_field {
					value = LrView.bind "identity",
					fill = 1
				}
			}
		}
	}
end