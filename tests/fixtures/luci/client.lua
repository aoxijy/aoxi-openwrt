m.reset = false
m.submit = false

m:section(SimpleSection).template = "openclash/status"
if fs.uci_get_config("config", "oix_token") and fs.uci_get_config("config", "oix_show_info_page") == "1" then
	m:append(Template("openclash/oixcloud"))
end
