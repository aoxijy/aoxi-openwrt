module("luci.controller.service_menu_toggle", package.seeall)

function index()
	-- Re-register the parent node after third-party controllers (such as EasyTier)
	-- so the entire Services menu follows the persistent UCI switch.
	local page = entry({"admin", "services"}, firstchild(), "Services", 30)
	page.dependent = false
	page.uci_depends = {
		luci_service_menu = {
			main = { visible = "1" }
		}
	}
end

function action_toggle()
	local http = require "luci.http"
	local uci = require "luci.model.uci".cursor()
	local visible = http.formvalue("visible")

	if visible ~= "0" and visible ~= "1" then
		http.status(400, "Bad Request")
		http.prepare_content("text/plain")
		http.write("Invalid visible value")
		return
	end

	if not uci:get("luci_service_menu", "main") then
		uci:section("luci_service_menu", "settings", "main", {})
	end

	uci:set("luci_service_menu", "main", "visible", visible)
	uci:commit("luci_service_menu")

	luci.sys.call("rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* /tmp/luci-modulecache/* 2>/dev/null")
	http.redirect(luci.dispatcher.build_url("admin", "status", "overview") .. "?service_menu_visible=" .. visible)
end
