#!/usr/bin/env ruby
# frozen_string_literal: true
#
# oc-smart.rb —— 本地"模型优选节点"
#
# 目标：
#   1. 每个节点保留最近 N 次（默认 10 次）测速记录，按「延迟 + 抖动 + 超时」算一个稳定性得分
#   2. 每个分组只在自己的成员里挑最优（绝不跨组），当前节点没有明显更差就不切（防抖）
#   3. 手动在面板上改过的分组会"让位"一段时间，不跟用户抢
#
# 用法（一般通过 oc-smart.sh 调用）：
#   oc-smart.rb cycle      测一轮 + 重新选一次（cron 用这个）
#   oc-smart.rb select     只用已有记录重新选一次（不测速，很快）
#   oc-smart.rb status     打印每组的当前节点/得分/候选前几名
#   oc-smart.rb reset      清空记录
#
# 依赖：ruby（OpenClash 本身就要）、mihomo 的 external-controller API

begin
  require 'json'
  HAVE_JSON = true
rescue LoadError
  HAVE_JSON = false
end
require 'yaml'

CONF_FILE = '/etc/openclash/custom/oc-smart.conf'
STATE_DIR = '/etc/openclash/smart'
HISTORY_FILE = File.join(STATE_DIR, 'history.json')
STATE_FILE = File.join(STATE_DIR, 'state.json')
LOG_FILE = ENV['OC_SMART_LOG'] || '/tmp/openclash_smart.log'

# ---------- 配置 ----------
DEFAULTS = {
  'HISTORY' => '10',                     # 每个节点保留多少次测试记录
  'TIMEOUT' => '3000',                   # 单节点测速超时(ms)
  'TEST_URL' => 'http://www.gstatic.com/generate_204',
  'TOLERANCE_MS' => '30',                # 新节点至少比当前快这么多才切
  'TOLERANCE_PCT' => '10',               # 或者快 10% 以上
  'MIN_SWITCH_INTERVAL' => '120',        # 同一组两次自动切换的最小间隔(秒)
  'MANUAL_HOLD' => '1800',               # 手动改过之后让位多久(秒)
  'CONCURRENCY' => '8',                  # 并发测速数
  'MIN_SAMPLES' => '3',                  # 至少几条记录才参与"稳定性"评选
  # 模型接管的「节点级」分组（成员是真实节点）
  'NODE_GROUPS' => '♻️ 自动选择|♻️ 香港自动|♻️ 亚洲自动|♻️ 美国自动|♻️ 其他自动|🕸️ CHATGPT自动',
  # 模型接管的「分类级」分组（成员是别的分组），默认不接管
  'CATEGORY_GROUPS' => '',
  # 永远不自动选的候选（保持策略语义）
  'NEVER' => 'DIRECT|REJECT|REJECT-DROP|PASS|COMPATIBLE'
}.freeze

def load_conf
  conf = DEFAULTS.dup
  group_urls = []
  if File.exist?(CONF_FILE)
    File.readlines(CONF_FILE).each do |line|
      line = line.strip
      next if line.empty? || line.start_with?('#') || !line.include?('=')

      k, v = line.split('=', 2)
      k = k.strip
      v = v.to_s.strip.gsub(/\A["']|["']\z/, '')
      # 允许同一个键写多行（GROUP_TEST_URL 要配多个分组）
      if k == 'GROUP_TEST_URL'
        group_urls << v
        next
      end
      conf[k] = v
    end
  end
  conf['GROUP_TEST_URLS'] = group_urls
  conf
end

# 分组 -> [测速地址, expected]，没配就用全局 TEST_URL
def build_group_urls
  map = {}
  (CONF['GROUP_TEST_URLS'] || []).each do |entry|
    parts = entry.split('|').map(&:strip)
    next if parts.size < 2 || parts[0].to_s.empty? || parts[1].to_s.empty?

    map[parts[0]] = [parts[1],
                     (parts[2].to_s.empty? ? nil : parts[2]),
                     (parts[3].to_s.empty? ? nil : parts[3].to_i)]
  end
  map
end

# 懒加载：CONF 在这之后才赋值
def group_urls
  @group_urls ||= build_group_urls
end

# 实际组名 -> 配置里的名字（配置里写的名字和实际组名有出入时也能对上）
GROUP_CFG = {}

# 把配置里写的组名解析成"实际存在的组名"：先精确匹配，再按包含关系兜底
def resolve_group(cfg_name, proxies)
  return cfg_name if proxies.key?(cfg_name)

  candidates = proxies.keys.select { |k| k.to_s.include?(cfg_name) || cfg_name.to_s.include?(k.to_s) }
  candidates.min_by(&:length)
end

def resolve_groups(proxies)
  all = (CONF['NODE_GROUPS'].split('|') + CONF['CATEGORY_GROUPS'].split('|')).map(&:strip).reject(&:empty?)
  resolved = []
  all.each do |cfg|
    actual = resolve_group(cfg, proxies)
    if actual.nil?
      log "[warn] 配置里写的组「#{cfg}」在配置里找不到，跳过"
      next
    end
    log "[info] 组「#{cfg}」-> 实际「#{actual}」" if actual != cfg
    GROUP_CFG[actual] = cfg
    resolved << actual
  end
  resolved.uniq
end

def group_test_target(group)
  key = GROUP_CFG[group] || group
  group_urls[key] || [CONF['TEST_URL'], nil, nil]
end

# 某个分组的测速超时：分组自己配了就用它，否则用全局 TIMEOUT
def group_timeout(group)
  (_u, _e, t) = group_test_target(group)
  t && t.positive? ? t : CONF['TIMEOUT'].to_i
end

def group_test_url(group)
  group_test_target(group)[0]
end

CONF = load_conf
SECRET = ENV['OC_SECRET'] || `uci -q get openclash.config.dashboard_password 2>/dev/null`.strip
API_BASE = ENV['OC_API'] || 'http://127.0.0.1:9090'
# --force: 忽略"手动让位"，强制按模型结果重选
FORCE = ARGV.include?('--force') || ENV['OC_SMART_FORCE'] == '1'
HISTORY_N = CONF['HISTORY'].to_i
GROUP_TYPES = %w[Selector URLTest Fallback LoadBalance Relay Compatible].freeze
NEVER = CONF['NEVER'].split('|').map(&:strip)

# OpenWrt 的 ruby 把 fileutils 也拆包了，自己实现一个最小 mkdir -p
def mkdir_p(dir)
  path = ''
  dir.split('/').reject(&:empty?).each do |part|
    path += "/#{part}"
    Dir.mkdir(path) unless File.directory?(path)
  end
rescue StandardError
  nil
end

def log(msg)
  mkdir_p(File.dirname(LOG_FILE))
  # 日志别无限涨，超过 256KB 截掉一半
  if File.exist?(LOG_FILE) && File.size(LOG_FILE) > 262_144
    lines = File.readlines(LOG_FILE)
    File.write(LOG_FILE, lines[(lines.size / 2)..].join)
  end
  File.open(LOG_FILE, 'a') { |f| f.puts("#{Time.now.strftime('%m-%d %H:%M:%S')} #{msg}") }
  puts msg
end

def enc(str)
  str.to_s.gsub(/[^A-Za-z0-9\-_.~]/) { |c| c.bytes.map { |b| format('%%%02X', b) }.join }
end

# 用 curl 调 mihomo 的 API（OpenWrt 的 ruby 把 net/http 拆成独立包了，curl 反而一定在）
def curl(args, max_time: 30)
  cmd = ['curl', '-s', '--max-time', max_time.to_s, '-H', "Authorization: Bearer #{SECRET}"] + args
  out = IO.popen(cmd, &:read)
  [($?.exitstatus || 1), out]
rescue StandardError => e
  log "[warn] curl 失败: #{e.message}"
  [1, nil]
end

def api_get(path, max_time: 30)
  curl(["#{API_BASE}#{path}"], max_time: max_time)
end

def api_put(path, body)
  return [1, nil] unless HAVE_JSON

  curl(['-X', 'PUT', '-H', 'Content-Type: application/json', '-d', JSON.generate(body),
        "#{API_BASE}#{path}"], max_time: 10)
end

def fetch_proxies
  return nil unless HAVE_JSON

  code, body = api_get('/proxies')
  return nil unless code.zero? && body && !body.empty?

  JSON.parse(body)['proxies'] || {}
rescue StandardError
  nil
end

# 真实节点（排除策略组、内置策略）
def node?(proxies, name)
  p = proxies[name]
  return false unless p
  return false if GROUP_TYPES.include?(p['type'].to_s)
  return false if NEVER.include?(name)

  true
end

# 测一个节点的延迟：返回 ms(Integer) 或 nil(超时/失败)
def test_delay(name, url = nil, expected = nil, timeout = nil)
  return nil unless HAVE_JSON

  url ||= CONF['TEST_URL']
  tmo = (timeout || CONF['TIMEOUT']).to_i
  q = "timeout=#{tmo}&url=#{enc(url)}"
  q += "&expected=#{enc(expected)}" if expected && !expected.empty?
  wait = (tmo / 1000.0).ceil + 3
  code, body = api_get("/proxies/#{enc(name)}/delay?#{q}", max_time: wait)
  return nil unless code.zero? && body && !body.empty?

  d = JSON.parse(body)['delay']
  d.is_a?(Numeric) ? d.to_i : nil
rescue StandardError
  nil
end

def load_json(path, fallback)
  return fallback unless HAVE_JSON && File.exist?(path)

  JSON.parse(File.read(path))
rescue StandardError
  fallback
end

def save_json(path, data)
  return unless HAVE_JSON

  mkdir_p(File.dirname(path))
  tmp = "#{path}.tmp#{Process.pid}"
  File.write(tmp, JSON.generate(data))
  File.rename(tmp, path)
end

def history
  @history ||= begin
    h = load_json(HISTORY_FILE, { 'by_url' => {} })
    h['by_url'] ||= {}
    # 兼容旧版结构：把 nodes 挪到全局测速地址下面
    if h['nodes'].is_a?(Hash) && !h['nodes'].empty?
      h['by_url'][CONF['TEST_URL']] ||= {}
      h['nodes'].each { |k, v| h['by_url'][CONF['TEST_URL']][k] ||= v }
      h.delete('nodes')
    end
    h
  end
end

# 取某节点在某个测速地址下的最近 N 条记录
def rec_for(h, url, node)
  bucket = h['by_url'][url]
  bucket ? bucket[node] : nil
end

# ---------- 得分模型 ----------
# 最近 N 条记录里：
#   avg   = 成功测速的平均延迟
#   sd    = 延迟标准差（抖动，越大越不稳定）
#   fail  = 超时次数
#   score = avg + 2*sd + (fail/N)*5000
#          ↑延迟      ↑抖动惩罚   ↑每次超时按 500ms 计入(满窗口 5000ms)
# 记录不足 MIN_SAMPLES 条时只按 avg 排，不给稳定性加分（避免"只测过一次很快"就抢走）
# 某节点在某地址下最近一次记录
def last_rec(h, url, node)
  r = rec_for(h, url, node)
  r && r.last
end

def score_of(records, min_samples)
  return nil if records.nil? || records.empty?

  oks = records.map { |r| r['ms'] }.compact
  n = records.size
  fail = n - oks.size
  return { score: 99_999, avg: nil, sd: nil, fail: fail, n: n } if oks.empty?

  avg = oks.sum.to_f / oks.size
  sd = if oks.size > 1
         Math.sqrt(oks.sum { |x| (x - avg)**2 } / (oks.size - 1))
       else
         0.0
       end
  penalty = (fail.to_f / n) * 5000
  raw = avg + (2 * sd) + penalty
  # 样本不够时保守一点：按 1.2 倍计入（相当于略微不信任）
  raw *= 1.2 if n < min_samples
  { score: raw.round(1), avg: avg.round(1), sd: sd.round(1), fail: fail, n: n }
end

# 组候选的得分：节点直接算；嵌套分组用它当前选中的节点算
def candidate_score(proxies, hist, name, min_samples, url = nil, depth = 0)
  url ||= CONF['TEST_URL']
  if node?(proxies, name)
    return score_of(rec_for(hist, url, name), min_samples)
  end
  p = proxies[name]
  return nil unless p && p['now'] && depth < 3

  candidate_score(proxies, hist, p['now'], min_samples, url, depth + 1)
end

# 从配置里读出「节点 -> 服务器」，用来避免同时测同一台服务器的多个节点
# （实测 198 个"节点"只对应 93 台服务器，其中一台挂着 34 个；并发打同一台会被限速，
#   测出来 2~8 秒甚至超时，而真实浏览只有 1 条连接所以很快）
def load_node_servers
  path = `uci -q get openclash.config.config_path 2>/dev/null`.strip
  return {} if path.empty? || !File.exist?(path)

  data = YAML.unsafe_load_file(path)
  map = {}
  (data['proxies'] || []).each do |p|
    next unless p.is_a?(Hash) && p['name'] && p['server']

    map[p['name']] = p['server'].to_s
  end
  map
rescue StandardError => e
  log "[warn] 读服务器映射失败: #{e.message}"
  {}
end

# ---------- 测速 ----------
def run_cycle(groups, proxies)
  jobs = {}
  groups.each do |g|
    url, expected, tmo = group_test_target(g)
    info = proxies[g]
    next unless info && info['all']

    info['all'].each do |m|
      jobs[[url, expected, tmo || CONF['TIMEOUT'].to_i, m]] = true if node?(proxies, m)
    end
  end
  jobs = jobs.keys
  targets = jobs.map { |j| [j[0], j[2]] }.uniq
  log "[cycle] 本轮要测 #{jobs.size} 次（#{groups.size} 个组，#{targets.size} 种测速目标，并发 #{CONF['CONCURRENCY']}）"
  targets.each { |u, t| log "[cycle]   测速地址: #{u}（超时 #{t}ms）" }

  hist = history
  servers = load_node_servers
  # 取服务器名；取不到的用节点名当唯一 key（等于不限制）
  skey = ->(name) { servers[name] || "unknown:#{name}" }

  queue = jobs.dup
  workers = [CONF['CONCURRENCY'].to_i, 1].max
  inflight = {}
  done = 0
  okc = 0
  mutex = Mutex.new
  t0 = Time.now

  threads = Array.new(workers) do
    Thread.new do
      loop do
        # 挑一个"它的服务器当前没有在测"的任务，实现同服务器串行
        job = mutex.synchronize do
          i = queue.index { |j| !inflight[skey.call(j[3])] }
          break nil if i.nil?

          chosen = queue.delete_at(i)
          inflight[skey.call(chosen[3])] = true
          chosen
        end
        break if job.nil?

        url, expected, tmo, name = job
        begin
          ms = test_delay(name, url, expected, tmo)
          mutex.synchronize do
            bucket = (hist['by_url'][url] ||= {})
            rec = (bucket[name] ||= [])
            rec << { 't' => Time.now.to_i, 'ms' => ms }
            rec.shift while rec.size > HISTORY_N
            done += 1
            okc += 1 if ms
          end
        ensure
          mutex.synchronize { inflight.delete(skey.call(name)) }
        end
      end
    end
  end
  threads.each(&:join)
  hist['updated'] = Time.now.to_i
  save_json(HISTORY_FILE, hist)
  log "[cycle] 完成：#{done} 次，成功 #{okc}，耗时 #{(Time.now - t0).round(1)}s"
end

# ---------- 选择 ----------
def run_select(groups, proxies)
  hist = history
  state = load_json(STATE_FILE, { 'groups' => {} })
  state['groups'] ||= {}
  now_t = Time.now.to_i
  min_samples = CONF['MIN_SAMPLES'].to_i
  switched = 0

  groups.each do |g|
    info = proxies[g]
    unless info
      log "[select] 跳过 #{g}：API 里找不到这个组"
      next
    end
    if info['type'] != 'Selector'
      log "[select] 跳过 #{g}：类型是 #{info['type']}，模型只能控制 select 组（跑 oc-smart.sh convert）"
      next
    end

    turl = group_test_url(g)
    cands = (info['all'] || []).reject { |n| NEVER.include?(n) }
    scored = cands.map { |n| [n, candidate_score(proxies, hist, n, min_samples, turl)] }
                  .reject { |_n, s| s.nil? }
                  .sort_by { |_n, s| s[:score] }
    if scored.empty?
      log "[select] #{g}：还没有可用记录，跳过"
      next
    end

    cur = info['now']
    cur_score = candidate_score(proxies, hist, cur, min_samples, turl)
    best, bstat = scored.first
    st = state['groups'][g] ||= {}

    # 手动改过 → 让位一段时间（但只在这个节点"确实有测速数据且不算差"时才让位；
    # 换配置/换节点后当前节点可能根本没有记录，这时必须让模型重新挑，否则会卡在死节点上）
    # --force 时忽略让位，强制重选
    if !FORCE && st['set'] && cur && cur != st['set'] && cur_score && cur_score[:fail] < (cur_score[:n] * 0.5)
      held = now_t - (st['manual_at'] ||= now_t)
      if held < CONF['MANUAL_HOLD'].to_i
        log "[select] #{g}：检测到手动选了「#{cur}」，让位 #{(CONF['MANUAL_HOLD'].to_i - held) / 60} 分钟"
        next
      end
    end

    # 切换判据
    # 当前节点是否"连续两次都测不通"（单次失败可能是噪声，不立刻切，避免来回抖）
    cur_recs = rec_for(hist, turl, cur) || []
    tail2 = cur_recs.last(2)
    cur_dead2 = tail2.size == 2 && tail2.all? { |r| r['ms'].nil? }
    best_last = last_rec(hist, turl, best)
    dead_cur = cur_dead2 && !best_last.nil? && !best_last['ms'].nil?
    need = if cur.nil? || cur_score.nil?
             true
           elsif dead_cur
             true   # 当前节点最近一次就测不通、候选最近一次是通的 → 立刻切（不等窗口攒满）
           elsif bstat[:fail].zero? && cur_score[:fail].positive?
             true   # 当前节点有超时、候选没有 → 立刻切
           else
             better = cur_score[:score] - bstat[:score]
             better >= CONF['TOLERANCE_MS'].to_i && better >= cur_score[:score] * CONF['TOLERANCE_PCT'].to_f / 100
           end
    unless need
      log "[select] #{g}：保持「#{cur}」(#{fmt(cur_score)})，最优「#{best}」#{fmt(bstat)} 未达切换阈值"
      next
    end

    if !dead_cur && st['last_switch'] && now_t - st['last_switch'] < CONF['MIN_SWITCH_INTERVAL'].to_i
      log "[select] #{g}：想切到「#{best}」但距上次切换不足 #{CONF['MIN_SWITCH_INTERVAL']}s，本轮不动"
      next
    end

    code, _body = api_put("/proxies/#{enc(g)}", { 'name' => best })
    if code.zero?
      log "[select] #{g}：切到「#{best}」#{fmt(bstat)}（原「#{cur}」#{fmt(cur_score)}）"
      st['set'] = best
      st['last_switch'] = now_t
      st.delete('manual_at')
      switched += 1
    else
      log "[select] #{g}：切换失败 HTTP #{code}"
    end
  end
  save_json(STATE_FILE, state)
  log "[select] 本轮切换 #{switched} 个组"
end

def short(name)
  name.to_s.sub('GQRU-', '').gsub(' | ', '/')
end

def fmt(s)
  return '∞' if s.nil?

  "均#{s[:avg]}ms 抖#{s[:sd]} 超时#{s[:fail]}/#{s[:n]} 分#{s[:score]}"
end

# ---------- 把被接管的组改成 select（模型才能控制它的选择）----------
FOUR_BYTE_ESCAPE = /\\U(0001[0-9A-Fa-f]{4})/.freeze

def dump_yaml(data)
  YAML.dump(data).gsub(FOUR_BYTE_ESCAPE) { [Regexp.last_match(1).hex].pack('U') }
end

def config_paths
  src = `uci -q get openclash.config.config_path 2>/dev/null`.strip
  list = []
  list << src unless src.empty?
  list << "/etc/openclash/#{File.basename(src)}" unless src.empty?
  list.select { |p| File.exist?(p) }.uniq
end

def convert_groups(mode, groups, paths = nil)
  changed = []
  (paths || config_paths).each do |path|
    data = begin
      YAML.unsafe_load_file(path)
    rescue StandardError => e
      log "[#{mode}] 读不了 #{path}: #{e.message}"
      nil
    end
    next unless data.is_a?(Hash)

    touched = false
    (data['proxy-groups'] || []).each do |g|
      next unless g.is_a?(Hash) && groups.include?(g['name'])

      if mode == 'convert'
        next if g['type'] == 'select'

        g['type'] = 'select'
        %w[url interval tolerance lazy expected-status strategy].each { |k| g.delete(k) }
        touched = true
      else
        next if g['type'] == 'url-test'

        # 交回内核（url-test）时，把该组的专用测速地址一起写进去，
        # 这样即使模型挂了，ChatGPT 组仍然是按 chatgpt.com 的地址在测
        turl, texp, _tmo = group_test_target(g['name'])
        g['type'] = 'url-test'
        g['url'] = turl || CONF['TEST_URL']
        g['expected-status'] = texp if texp && !texp.empty?
        g['interval'] = 300
        g['tolerance'] = 150
        touched = true
      end
    end
    next unless touched

    File.write(path, dump_yaml(data))
    changed << path
  end
  changed
end

# ---------- 给网页面板输出数据（/ui/mrs-panel/ 同源读取，不需要额外服务）----------
PANEL_JSON = '/usr/share/openclash/ui/mrs-panel/history.json'

def write_panel_json(proxies, hist, groups)
  return unless HAVE_JSON

  min_samples = CONF['MIN_SAMPLES'].to_i
  scores = {}
  nodes = {}
  grp = {}
  groups.each do |g|
    info = proxies[g]
    next unless info

    turl = group_test_url(g)
    grp[g] = { 'now' => info['now'], 'type' => info['type'],
               'members' => (info['all'] || []).size, 'test_url' => turl }
    (info['all'] || []).each do |nm|
      next unless node?(proxies, nm)

      key = "#{turl}|#{nm}"
      nodes[key] ||= rec_for(hist, turl, nm) || []
      next if scores.key?(key)

      sc = score_of(rec_for(hist, turl, nm), min_samples)
      scores[key] = sc if sc
    end
  end
  data = {
    'updated' => Time.now.to_i, 'history_n' => HISTORY_N,
    'groups' => grp, 'scores' => scores, 'nodes' => nodes
  }
  # LuCI 面板要读的纯文本状态（LuCI 里没有 json 解析库，用 key=value 最省事）
  begin
    uniq_nodes = nodes.keys.map { |k| k.split('|', 2)[1] }.uniq
    lines = []
    lines << "updated=#{Time.now.to_i}"
    lines << "nodes=#{uniq_nodes.size}"
    lines << "scores=#{scores.size}"
    lines << "test_urls=#{grp.values.map { |v| v['test_url'] }.uniq.size}"
    lines << "history_n=#{HISTORY_N}"
    lines << "min_switch_interval=#{CONF['MIN_SWITCH_INTERVAL']}"
    grp.each { |g, v| lines << "now.#{g}=#{v['now']}" }
    grp.each { |g, v| lines << "url.#{g}=#{v['test_url']}" }
    # 最近一轮每个地址的成功/超时统计
    (hist['by_url'] || {}).each do |u, bucket|
      ok = bucket.count { |_n, rec| rec.last && rec.last['ms'] }
      lines << "stat.#{u}=#{ok}/#{bucket.size}"
    end
    File.write('/etc/openclash/smart/status.txt', lines.join("\n") + "\n")
  rescue StandardError => e
    log "[warn] 写 status.txt 失败: #{e.message}"
  end

  [PANEL_JSON, '/etc/openclash/smart/panel.json'].each do |path|
    next if File.directory?(File.dirname(path)) == false && path == PANEL_JSON && !File.directory?('/usr/share/openclash/ui')

    mkdir_p(File.dirname(path))
    begin
      File.write(path, JSON.generate(data))
    rescue StandardError => e
      log "[warn] 写面板数据失败 #{path}: #{e.message}"
    end
  end
end

# 被接管的组必须先是 select，模型才能控制它的选择。
# 换了整套配置/订阅后组类型常常会变回 url-test —— 这里自动转换 + 让内核热重载配置。
def ensure_groups_selectable(groups, proxies)
  needs = groups.select { |g| proxies[g] && proxies[g]['type'] != 'Selector' }
  return if needs.empty?

  log "[auto] 这些被接管的组不是 select（模型控制不了），自动转换: #{needs.join(', ')}"
  changed = convert_groups('convert', needs)
  return if changed.empty?

  path = `uci -q get openclash.config.config_path 2>/dev/null`.strip
  rt = path.empty? ? nil : "/etc/openclash/#{File.basename(path)}"
  return unless rt && File.exist?(rt)

  code, _body = curl(['-X', 'PUT', '-H', 'Content-Type: application/json',
                      '-d', JSON.generate({ 'path' => rt, 'force' => true }),
                      "#{API_BASE}/configs?force=true"], max_time: 60)
  log "[auto] 已热重载 #{rt}（curl 退出码 #{code}），组类型转换立即生效"
end

# 清理记录：**按测速地址分别清** —— 每个地址下只保留"用这个地址测的那些组"的当前成员。
# 这样换了一批节点、或某节点被移出某个分组后，不会留下永远不再更新的旧记录。
def prune_history(hist, proxies, groups)
  keep = Hash.new { |h, k| h[k] = {} }
  groups.each do |g|
    info = proxies[g]
    next unless info

    url = group_test_url(g)
    (info['all'] || []).each { |n| keep[url][n] = true }
  end
  removed = 0
  (hist['by_url'] || {}).each do |url, bucket|
    bucket.keys.each do |n|
      next if keep[url][n]

      bucket.delete(n)
      removed += 1
    end
  end
  removed
end

# ---------- 快速守护 ----------
# 只测"每个被接管分组当前选中的节点"（每分钟一次，最多 6 次请求），
# 连续两次不通就立刻换成"最近一次通过"的候选 —— 不用等整轮 cycle（5 分钟太久，
# 实测遇到过节点在两次测速之间死掉：测速记录还很好看，但真实流量已经 i/o timeout）。
def run_guard(groups, proxies)
  hist = history
  state = load_json(STATE_FILE, { 'groups' => {} })
  state['groups'] ||= {}
  min_samples = CONF['MIN_SAMPLES'].to_i
  verify_max = (CONF['GUARD_VERIFY_MAX'] || 6).to_i
  switched = 0

  groups.each do |g|
    info = proxies[g]
    next unless info && info['type'] == 'Selector'

    cur = info['now']
    next if cur.nil? || NEVER.include?(cur)

    turl, texp, tmo = group_test_target(g)
    bucket = (hist['by_url'][turl] ||= {})
    rec = (bucket[cur] ||= [])

    ms = test_delay(cur, turl, texp, tmo)
    rec << { 't' => Time.now.to_i, 'ms' => ms }
    rec.shift while rec.size > HISTORY_N

    if ms.nil?
      # 单次抖动不算数：同一次 guard 里立刻复测一次，避免来回切
      ms = test_delay(cur, turl, texp, tmo)
      rec << { 't' => Time.now.to_i, 'ms' => ms }
      rec.shift while rec.size > HISTORY_N
    end
    next if ms   # 复测通了 → 不折腾

    # 连测两次都不通：按分数取候选，**逐个实测验证**，第一个实测通的才切过去。
    # 这一步是关键：以前只按历史分数选，切过去可能又是个死节点（用户体感就是"切了还是打不开"）。
    cands = (info['all'] || [])
            .reject { |x| NEVER.include?(x) || x == cur }
            .map { |x| [x, candidate_score(proxies, hist, x, min_samples, turl)] }
            .sort_by { |_x, sc| sc ? sc[:score] : Float::INFINITY }
    best = nil
    tried = 0
    cands.each do |x, sc|
      break if tried >= verify_max

      tried += 1
      v = test_delay(x, turl, texp, tmo)
      vb = (hist['by_url'][turl] ||= {})
      vr = (vb[x] ||= [])
      vr << { 't' => Time.now.to_i, 'ms' => v }
      vr.shift while vr.size > HISTORY_N
      next unless v

      best = [x, sc, v]
      break
    end

    if best.nil?
      log "[guard] #{g}: 当前「#{cur}」连测两次不通；候选实测了 #{tried} 个也都不通 → 先保持不动（下一轮再试）"
      next
    end

    code, _b = api_put("/proxies/#{enc(g)}", { 'name' => best[0] })
    if code.zero?
      log "[guard] #{g}: 当前「#{cur}」连测两次不通 → 实测通过后切到「#{best[0]}」#{best[2]}ms#{best[1] ? "（分 #{best[1][:score]}，候选实测 #{tried} 个）" : ""}"
      st = state['groups'][g] ||= {}
      st['set'] = best[0]
      st['last_switch'] = Time.now.to_i
      st.delete('manual_at')
      switched += 1
    else
      log "[guard] #{g}: 切换到「#{best[0]}」失败（HTTP 退出码 #{code}）"
    end
  end

  hist['updated'] = Time.now.to_i
  save_json(HISTORY_FILE, hist)
  save_json(STATE_FILE, state)
  proxies = fetch_proxies || proxies
  write_panel_json(proxies, hist, groups)
  log "[guard] 检查 #{groups.size} 个组，立即切换 #{switched} 个" if switched.positive?
end

# ---------- status ----------
def run_status(groups, proxies)
  hist = history
  min_samples = CONF['MIN_SAMPLES'].to_i
  puts format('%-16s %-26s %-30s %s', '分组', '当前节点', '当前得分', '候选前三')
  groups.each do |g|
    info = proxies[g]
    next unless info

    turl = group_test_url(g)
    cands = (info['all'] || []).reject { |n| NEVER.include?(n) }
                              .map { |n| [n, candidate_score(proxies, hist, n, min_samples, turl)] }
                              .reject { |_n, s| s.nil? }
                              .sort_by { |_n, s| s[:score] }
    cur = info['now']
    top = cands.first(3).map { |n, s| "#{short(n)}(#{s[:score]})" }.join('  ')
    tag = turl == CONF['TEST_URL'] ? '' : "  [测速: #{turl}]"
    puts format('%-16s %-26s %-30s %s%s', g, cur.to_s, fmt(candidate_score(proxies, hist, cur, min_samples, turl)), top, tag)
  end
  buckets = (hist['by_url'] || {}).map { |u, b| "#{u} → #{b.size} 个节点" }
  puts "\n记录（每节点保留最近 #{HISTORY_N} 次）：#{buckets.join('；')}；更新 #{Time.at(hist['updated'] || 0)}"
end

# ---------- main ----------
cmd = ARGV[0] || 'cycle'

# convert / revert 只改配置文件，不需要 mihomo 在跑（首次开机 uci-defaults 阶段就要能用）
if %w[convert revert].include?(cmd)
  wanted = (CONF['NODE_GROUPS'].split('|') + CONF['CATEGORY_GROUPS'].split('|')).map(&:strip).reject(&:empty?)
  only = ARGV[1]
  if only && File.exist?(only)
    # 只改这一个文件（OpenClash 钩子里改 /tmp 下那份运行配置用，不需要 API）
    changed = convert_groups(cmd, wanted, [only])
  else
    prox = fetch_proxies
    wanted = resolve_groups(prox) if prox   # 有 API 就用解析后的实际组名，没有就用配置里的名字
    changed = convert_groups(cmd, wanted)
  end
  if changed.empty?
    log "[#{cmd}] 没有需要改的（已经是目标类型）"
  else
    log "[#{cmd}] 已修改：#{changed.join(', ')}"
    log "[#{cmd}] 改的是配置文件，需要热重载或重启 OpenClash 生效"
  end
  exit 0
end

unless HAVE_JSON
  abort '[oc-smart] 缺少 ruby-json 库（opkg install ruby-json）；' \
        'convert/revert 仍然可用，其余命令不可用'
end

proxies = fetch_proxies
abort '[oc-smart] 连不上 mihomo API（external-controller）' unless proxies

groups = resolve_groups(proxies)
node_groups = groups   # 兜底用

case cmd
when 'guard'
  run_guard(groups, proxies)
when 'cycle'
  ensure_groups_selectable(groups, proxies)
  proxies = fetch_proxies || proxies
  groups = resolve_groups(proxies)
  n = prune_history(history, proxies, groups)
  if n.positive?
    save_json(HISTORY_FILE, history)
    log "[cycle] 清理了 #{n} 条已不在分组里的节点记录"
  end
  run_cycle(groups, proxies)
  proxies = fetch_proxies
  run_select(groups, proxies)
  write_panel_json(fetch_proxies || proxies, history, groups)
when 'select'
  n = prune_history(history, proxies, groups)
  if n.positive?
    save_json(HISTORY_FILE, history)   # 清理结果要落盘
    log "[select] 清理了 #{n} 条已不在分组里的记录"
  end
  run_select(groups, proxies)
  write_panel_json(proxies, history, groups)
when 'status'
  run_status(groups, proxies)
when 'reset'
  save_json(HISTORY_FILE, { 'nodes' => {}, 'updated' => Time.now.to_i })
  save_json(STATE_FILE, { 'groups' => {} })
  log '[reset] 记录已清空'
when 'type'
  # 看看这些组现在是什么类型（模型只能控制 select 组）
  groups.each { |g| puts format('%-16s %s  (成员 %d)', g, proxies[g]['type'], (proxies[g]['all'] || []).size) }
else
  abort "用法: #{$PROGRAM_NAME} [cycle|guard|select|status|type|convert|revert|reset]（convert/revert 不需要 API）"
end
