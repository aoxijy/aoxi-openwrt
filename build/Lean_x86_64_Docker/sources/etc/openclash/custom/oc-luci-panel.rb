#!/usr/bin/env ruby
# oc-luci-panel.rb —— 给 OpenClash 的 LuCI 增加「MRS 延迟面板」入口（幂等，可反复执行）
#
#   控制面板首页(/client)：多一张 MRS 面板卡片（打开按钮 + 状态点 + 最近一轮统计）
#   覆写设置(/settings) → Dashboard 设置：多一项 MRS Panel，可「设为默认面板」
#     —— 设为默认后，OpenClash 自己的「控制面板」按钮就会打开 mrs-panel
#
# 用法: oc-luci-panel.rb install | status | remove
#
# 说明：改的是 OpenClash 包自带的文件（client.lua / settings.lua / controller/openclash.lua），
#       所以刷固件或升级 OpenClash 后要重新跑一次 install。每次都会留 .bak.<时间戳>。

# OpenWrt 的 ruby 没有 fileutils，用系统命令 + 自己实现的 mkdir_p
def mkdir_p(dir)
  path = ''
  dir.split('/').reject(&:empty?).each do |part|
    path += "/#{part}"
    Dir.mkdir(path) unless File.directory?(path)
  end
rescue StandardError
  nil
end

def cp(src, dst)
  system('cp', '-f', src, dst)
end

def rm_rf(path)
  system('rm', '-rf', path)
end

TPL_SRC = '/etc/openclash/custom/luci'
VIEW_DIR = '/usr/lib/lua/luci/view/openclash'
CBI_DIR = '/usr/lib/lua/luci/model/cbi/openclash'
CTL = '/usr/lib/lua/luci/controller/openclash.lua'
STAMP = Time.now.strftime('%Y%m%d%H%M%S')
MARK = 'MRS-PANEL-PATCH'

def backup(path)
  return if path.include?('.bak.')
  cp(path, "#{path}.bak.#{STAMP}")
end

def patch(path, mode)
  src = File.read(path, encoding: 'UTF-8')
  orig = src.dup
  case mode
  when 'client.lua'
    unless src.include?(MARK)
      anchor = %(m:section(SimpleSection).template = "openclash/status"\n)
      abort "  ✗ #{path}: 找不到锚点" unless src.include?(anchor)
      src = src.sub(anchor, anchor + "-- #{MARK}: MRS 延迟面板入口\nm:append(Template(\"openclash/mrs_panel\"))\n")
    end
  when 'settings.lua'
    unless src.include?('MRSPanel')
      anchor = %(o = s:taboption("dashboard", DummyValue, "Dashboard", translate("Switch(Update) Dashboard Version")))
      abort "  ✗ #{path}: 找不到锚点" unless src.include?(anchor)
      add = %(o = s:taboption("dashboard", DummyValue, "MRSPanel", translate("MRS Panel (Delay Log)"))\n) +
            %(o.template = "openclash/mrs_panel_setting"\n) +
            %(o.description = translate("Local panel: hover a delay bar to see the latest 10 connectivity tests. Set it as default and the OpenClash control-panel button will open it.")\n\n)
      src = src.sub(anchor, add + anchor)
    end
  when 'controller'
    unless src.include?('MRSPanel = "mrs-panel"')
      a1 = %(\t\tzashboard = fs.isdirectory("/usr/share/openclash/ui/zashboard"),\n\t\tdefault_dashboard = default_dashboard;)
      abort "  ✗ #{path}: 找不到 dashboard_type 锚点" unless src.include?(a1)
      src = src.sub(a1, %(\t\tzashboard = fs.isdirectory("/usr/share/openclash/ui/zashboard"),\n\t\t["mrs-panel"] = fs.isdirectory("/usr/share/openclash/ui/mrs-panel"),\n\t\tdefault_dashboard = default_dashboard;))
      a2 = "\tif not default_dashboard or (default_dashboard ~= \"Dashboard\" and default_dashboard ~= \"Yacd\" and default_dashboard ~= \"Metacubexd\" and default_dashboard ~= \"Zashboard\") then\n\t\tHTTP.status(500, \"Set Failed\")\n\t\treturn\n\tend\n\tif not fs.isdirectory(\"/usr/share/openclash/ui/\" .. string.lower(default_dashboard)) then"
      unless src.include?(a2)
        abort "  ✗ #{path}: 找不到 default_dashboard 白名单锚点（OpenClash 版本变了？）"
      end
      rep = "\t-- 面板名 -> ui 目录名（MRS 面板目录带连字符，不能简单 string.lower）\n" \
            "\tlocal dashboard_dirs = {\n\t\tDashboard = \"dashboard\",\n\t\tYacd = \"yacd\",\n\t\tMetacubexd = \"metacubexd\",\n\t\tZashboard = \"zashboard\",\n\t\tMRSPanel = \"mrs-panel\",\n\t}\n" \
            "\tlocal dash_dir = default_dashboard and dashboard_dirs[default_dashboard]\n" \
            "\tif not dash_dir or not fs.isdirectory(\"/usr/share/openclash/ui/\" .. dash_dir) then"
      src = src.sub(a2, rep)
    end
  end
  if src != orig
    backup(path)
    File.write(path, src)
    puts "  ✓ 已打补丁 #{path}"
  else
    puts "  · 已是补丁状态 #{path}"
  end
end

def install
  puts '[install] 复制模板'
  mkdir_p(VIEW_DIR)
  %w[mrs_panel.htm mrs_panel_setting.htm].each do |f|
    src = File.join(TPL_SRC, f)
    abort "  ✗ 缺少模板 #{src}" unless File.exist?(src)
    cp(src, File.join(VIEW_DIR, f))
    puts "  ✓ #{f}"
  end

  puts '[install] 打 LuCI 补丁'
  patch(File.join(CBI_DIR, 'client.lua'), 'client.lua')
  patch(File.join(CBI_DIR, 'settings.lua'), 'settings.lua')
  patch(CTL, 'controller')

  puts '[install] 清 LuCI 缓存'
  Dir.glob('/tmp/luci-indexcache*').each { |f| rm_rf(f) }
  rm_rf('/tmp/luci-modulecache')
  puts '  ✓ 完成（浏览器刷新一下 LuCI 页面即可看到）'
end

def status
  puts '模板:'
  %w[mrs_panel.htm mrs_panel_setting.htm].each do |f|
    p = File.join(VIEW_DIR, f)
    puts "  #{File.exist?(p) ? '✓' : '✗'} #{p}"
  end
  puts '补丁:'
  checks = [
    [File.join(CBI_DIR, 'client.lua'), 'openclash/mrs_panel'],
    [File.join(CBI_DIR, 'settings.lua'), 'MRSPanel'],
    [CTL, 'MRSPanel = "mrs-panel"'],
  ]
  checks.each do |p, needle|
    ok = File.exist?(p) && File.read(p, encoding: 'UTF-8').include?(needle)
    puts "  #{ok ? '✓' : '✗'} #{p}"
  end
end

def remove
  puts '[remove] 还原备份'
  Dir.glob("#{CBI_DIR}/*.bak.*").sort.last(1).each { |f| puts "  (如需还原: cp #{f} #{f.sub(/\.bak\..*/, '')})" }
  puts "  (手动还原示例: cp #{CTL}.bak.<时间戳> #{CTL}；模板可直接删除)"
end

case ARGV[0] || 'install'
when 'install' then install
when 'status' then status
when 'remove' then remove
else abort 'usage: oc-luci-panel.rb install|status|remove'
end
