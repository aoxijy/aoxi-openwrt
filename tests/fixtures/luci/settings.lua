o.default = 0
o.description = translate("Is SSL enabled For Dashboard Login From Public Network")

o = s:taboption("dashboard", DummyValue, "Dashboard", translate("Switch(Update) Dashboard Version"))
o.template="openclash/switch_dashboard"
o.rawhtml = true

