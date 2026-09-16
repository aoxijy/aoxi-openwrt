		yacd_type = yacd_type,
		yacd = fs.isdirectory("/usr/share/openclash/ui/yacd"),
		dashboard = fs.isdirectory("/usr/share/openclash/ui/dashboard"),
		metacubexd = fs.isdirectory("/usr/share/openclash/ui/metacubexd"),
		zashboard = fs.isdirectory("/usr/share/openclash/ui/zashboard"),
		default_dashboard = default_dashboard;
	})
end

function action_default_dashboard()
	local default_dashboard = HTTP.formvalue("name")
	if not default_dashboard or (default_dashboard ~= "Dashboard" and default_dashboard ~= "Yacd" and default_dashboard ~= "Metacubexd" and default_dashboard ~= "Zashboard") then
		HTTP.status(500, "Set Failed")
		return
	end
	if not fs.isdirectory("/usr/share/openclash/ui/" .. string.lower(default_dashboard)) then
		HTTP.status(500, "Set Failed")
		return
	end
	uci:set("openclash", "config", "default_dashboard", string.lower(default_dashboard))
	uci:commit("openclash")
	HTTP.prepare_content("application/json")
	HTTP.write_json({
		default_dashboard = default_dashboard;
	})
end

