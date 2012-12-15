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
						title = "User:",
					},
					viewFactory:edit_field {
						value = LrView.bind "user",
						width_in_chars = 10
					}
				},
				viewFactory:column {
					viewFactory:static_text {
						title = "Host:",
					},
					viewFactory:edit_field {
						value = LrView.bind "host",
						width_in_chars = 10
					}
				},
				viewFactory:column {
					viewFactory:static_text {
						title = "Path to upload directory:",
					},
					viewFactory:edit_field {
						value = LrView.bind "destination_path",
						tooltip = "The path to the root directory of the upload where the collection directories will be put. The structure will be created if it does not exist.",
						fill = 1
					},
					fill = 1
				}
			},
			viewFactory:spacer {},
			viewFactory:row {
				viewFactory:static_text {
						title = "Identity file (private key):",
				},
				viewFactory:edit_field {
					value = LrView.bind "identity",
					tooltip = "The private part of a public/private key pair. The public part must be installed on the remote system, associated with your user. Use ssh-agent or an equivalent tool to create the key pair.",
					fill = 1
				}
			}
		}
	}
end