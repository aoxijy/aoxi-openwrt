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
  'HISTORY_MAX_AGE' => '3600',           # 评分只使用最近多少秒内的记录
  'MANUAL_HOLD' => '1800',               # 手动改过之后让位多久(秒)
  'CONCURRENCY' => '8',                  # 并发测速数
  'MIN_SAMPLES' => '3',                  # 至少几条记录才参与"稳定性"评选
  # 僵尸节点快速跳过：连续失败这么多次、且刚测过不超过 DEAD_PROBE_MINUTES 分钟的节点，
  # 本轮不再重测（成员资格和历史都保留，到点仍会复测，恢复后立刻回到候选池）
  'DEAD_SKIP' => '1',
  'DEAD_STREAK' => '3',
  'DEAD_PROBE_MINUTES' => '25',
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
  group_min_switch = []
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
      if k == 'GROUP_MIN_SWITCH_INTERVAL'
        group_min_switch << v
        next
      end
      conf[k] = v
    end
  end
  conf['GROUP_TEST_URLS'] = group_urls
  conf['GROUP_MIN_SWITCH_INTERVALS'] = group_min_switch
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

# 分组 -> 最短切换间隔覆盖；没配就用全局 MIN_SWITCH_INTERVAL
def build_group_min_switch_intervals
  map = {}
  (CONF['GROUP_MIN_SWITCH_INTERVALS'] || []).each do |entry|
    parts = entry.split('|').map(&:strip)
    next if parts.size < 2 || parts[0].to_s.empty?

    map[parts[0]] = parts[1].to_i
  end
  map
end

def group_min_switch_intervals
  @group_min_switch_intervals ||= build_group_min_switch_intervals
end

def group_min_switch_interval(group)
  key = GROUP_CFG[group] || group
  val = group_min_switch_intervals[key] || group_min_switch_intervals[group]
  val && val.positive? ? val : CONF['MIN_SWITCH_INTERVAL'].to_i
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
# 僵尸节点跳过：连续失败判定阈值 / 复测间隔（秒）
DEAD_SKIP = (CONF['DEAD_SKIP'] || '1').to_s != '0'
DEAD_STREAK = [(CONF['DEAD_STREAK'] || '3').to_i, 1].max
DEAD_PROBE_SEC = [(CONF['DEAD_PROBE_MINUTES'] || '25').to_i, 1].max * 60
# 连续失败到这个次数才算"真死"（按长间隔复测）；3~5 次的算"可能只是抖动"，短间隔复测
DEAD_DEEP_STREAK = [(CONF['DEAD_DEEP_STREAK'] || '6').to_i, DEAD_STREAK].max
DEAD_PROBE_SHALLOW_SEC = [(CONF['DEAD_PROBE_SHALLOW_MINUTES'] || '8').to_i, 1].max * 60

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

def recent_records(records)
  return records unless records.is_a?(Array)

  max_age = (CONF['HISTORY_MAX_AGE'] || '3600').to_i
  return records if max_age <= 0

  cutoff = Time.now.to_i - max_age
  records.select { |r| !r.is_a?(Hash) || !r.key?('t') || r['t'].to_i >= cutoff }
end

# 某个节点最近的「连续失败次数」：从最新一条往前数，连续 ms=nil 的条数
def fail_streak(records)
  return 0 unless records.is_a?(Array)

  n = 0
  records.reverse_each do |r|
    break unless r.is_a?(Hash) && r['ms'].nil?

    n += 1
  end
  n
end

# 僵尸节点：在窗口内连续失败 DEAD_STREAK 次以上（成功过的节点不会长期挂着这个标记）
def dead_node?(records)
  fail_streak(records) >= DEAD_STREAK
end

# 僵尸节点该不该在本轮复测：距上次"真正测过"它的时间超过复测间隔，才再试一次。
# 注意：不能拿最近一条测速记录的 t 来判断 —— 每轮都测就等于每轮都刷新，永远不到期，
# 跳过逻辑会空转（这正是第一版的问题）。所以单独记一个 last_probe 时间戳。
# 分两档：连续失败很多次的（真死）等 DEAD_PROBE_SEC；刚失败几轮的（可能只是抖动/被限速
# 的误判）只等 DEAD_PROBE_SHALLOW_SEC，尽快把它找回来。
def probe_due?(hist, url, node, records: nil)
  ts = history_probe_times
  key = "#{url}|#{node}"
  last = ts[key]
  return true if last.nil? || last <= 0

  records ||= rec_for(hist, url, node)
  streak = fail_streak(records)
  interval = streak >= DEAD_DEEP_STREAK ? DEAD_PROBE_SEC : [DEAD_PROBE_SHALLOW_SEC, DEAD_PROBE_SEC].min
  # 用 > 而不是 >=：周期正好落在间隔边界上时（8 分钟整、25 分钟整）留一点余量，
  # 避免"这一毫秒到了、下一毫秒没过"的边界抖动。
  Time.now.to_i - last.to_i > interval
end

def mark_probe(hist, url, node, t = Time.now.to_i)
  (hist['probe'] ||= {})["#{url}|#{node}"] = t
end

def history_probe_times
  history['probe'] ||= {}
end

# 本轮要不要跳过这个节点的测速（僵尸 + 刚测过）
def skip_dead_probe?(hist, url, name)
  return false unless DEAD_SKIP

  records = rec_for(hist, url, name)
  dead_node?(records) && !probe_due?(hist, url, name, records: records)
end

# 某个被接管分组里，每个节点实际会用到哪些测速地址（同一节点可能出现在多个组）。
# 有的节点只是"通用地址"不通、但 ChatGPT 地址通（实测 134 个里有 46 个是这样），
# 所以僵尸判定必须"在所有用到的测速地址上都不通"才能跳过，否则会把能用 ChatGPT 的节点
# 一起停掉。
def node_test_urls(groups, proxies)
  map = Hash.new { |h, k| h[k] = {} }
  groups.each do |g|
    info = proxies[g]
    next unless info && info['all']

    url = group_test_url(g)
    (info['all'] || []).each { |m| map[m][url] = true }
  end
  map
end

# 该节点本轮是否整体可跳过：所有参与的分组测速地址上都已是僵尸且都还没到复测时间。
# 注意这里必须用 urls.keys.all?：直接 urls.all? 时块参数拿到的是 [key, value] 数组，
# 会让判定永远失败（这是踩过的坑）。
def node_fully_skippable?(hist, name, urls)
  return false if urls.nil? || urls.empty?

  urls.keys.all? { |u| skip_dead_probe?(hist, u, name) }
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
  r = recent_records(rec_for(h, url, node))
  r && r.last
end

def score_of(records, min_samples)
  records = recent_records(records)
  return nil if records.nil? || records.empty?

  oks = records.map { |r| r['ms'] }.compact
  n = records.size
  fail = n - oks.size
  if oks.empty?
    # 全失败的节点给一个「按连续失败次数递进」的分数：
    # 以前统一 99999，僵尸节点之间无法排序（面板全是同一个分）；
    # 现在连续失败越多分越高，刚断的节点排在老僵尸前面，恢复后能优先被复测/选中。
    streak = fail_streak(records)
    return { score: 99_999 + [streak * 100, 10_000].min, avg: nil, sd: nil, fail: fail, n: n }
  end

  avg = oks.sum.to_f / oks.size
  sd = if oks.size > 1
         Math.sqrt(oks.sum { |x| (x - avg)**2 } / (oks.size - 1))
       else
         0.0
       end
  penalty = (fail.to_f / n) * 5000
  raw = avg + (2 * sd) + penalty
  # 样本不够时只加 2% 的轻微不信任：以前是 1.2 倍，会让"9 条记录"和"10 条记录"
  # 的节点分数不可比，样本数每轮变化（以及僵尸跳过）就会造成无意义的名次抖动。
  raw *= 1.02 if n < min_samples
  { score: raw.round(1), avg: avg.round(1), sd: sd.round(1), fail: fail, n: n }
end

# 组候选的得分：节点直接算；嵌套分组用它当前选中的节点算
# 排序时叠加一个「最近一次实测失败」的轻惩罚：不是直接淘汰（可能只是抖动），
# 而是让"刚测通过"的候选排在前面，避免把有限的实测验证次数花在刚超时的节点上。
LAST_FAIL_PENALTY = 2000

def candidate_rank(stat, records)
  return Float::INFINITY if stat.nil?

  last = records.is_a?(Array) ? records.last : nil
  last_failed = last.is_a?(Hash) && last['ms'].nil?
  stat[:score] + (last_failed ? LAST_FAIL_PENALTY : 0)
end

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
  hist = history
  url_map = node_test_urls(groups, proxies)
  jobs = {}
  skipped = {}
  groups.each do |g|
    url, expected, tmo = group_test_target(g)
    info = proxies[g]
    next unless info && info['all']

    info['all'].each do |m|
      next unless node?(proxies, m)

      job = [url, expected, tmo || CONF['TIMEOUT'].to_i, m]
      # 僵尸节点：在它参与的所有测速地址上都连续失败 DEAD_STREAK 次以上、且都还没到复测时间
      # → 本轮不测（省下大量超时等待），历史记录和成员资格都保留，到点自动复测。
      # 只在某一个地址上失败（例如通用地址不通但 ChatGPT 地址通）不算僵尸，照常测。
      if node_fully_skippable?(hist, m, url_map[m])
        skipped[job] = true
        next
      end
      jobs[job] = true
    end
  end
  jobs = jobs.keys
  targets = jobs.map { |j| [j[0], j[2]] }.uniq
  log "[cycle] 本轮要测 #{jobs.size} 次（#{groups.size} 个组，#{targets.size} 种测速目标，并发 #{CONF['CONCURRENCY']}）"
  log "[cycle] 跳过 #{skipped.size} 次僵尸节点的重复测速（所有测速地址上都连续失败≥#{DEAD_STREAK} 次且未到复测时间）" if skipped.size.positive?
  targets.each { |u, t| log "[cycle]   测速地址: #{u}（超时 #{t}ms）" }

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
            # 记下"真正测过"的时间，僵尸节点的复测间隔以它为准
            (hist['probe'] ||= {})["#{url}|#{name}"] = Time.now.to_i
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

def append_history_result(hist, url, node, ms)
  bucket = (hist['by_url'][url] ||= {})
  rec = (bucket[node] ||= [])
  rec << { 't' => Time.now.to_i, 'ms' => ms }
  rec.shift while rec.size > HISTORY_N
  (hist['probe'] ||= {})["#{url}|#{node}"] = Time.now.to_i
end

def verify_switch_candidate(hist, group, node)
  turl, texp, tmo = group_test_target(group)
  ms = test_delay(node, turl, texp, tmo)
  append_history_result(hist, turl, node, ms)
  ms
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
                  .sort_by { |n, s| candidate_rank(s, recent_records(rec_for(hist, turl, n))) }
    if scored.empty?
      log "[select] #{g}：还没有可用记录，跳过"
      next
    end

    cur = info['now']
    cur_score = candidate_score(proxies, hist, cur, min_samples, turl)
    cur_rank = candidate_rank(cur_score, recent_records(rec_for(hist, turl, cur)))
    best, bstat = scored.first
    best_rank = candidate_rank(bstat, recent_records(rec_for(hist, turl, best)))
    st = state['groups'][g] ||= {}

    # 手动改过 → 同一节点完整让位 MANUAL_HOLD；手动节点变化则重新计时。
    # --force 时忽略让位，强制重选。
    if !FORCE && st['set'] && cur && cur != st['set']
      if st['manual_node'] != cur
        st['manual_node'] = cur
        st['manual_at'] = now_t
      end
      held = now_t - st['manual_at'].to_i
      if held < CONF['MANUAL_HOLD'].to_i
        log "[select] #{g}：检测到手动选了「#{cur}」，让位 #{(CONF['MANUAL_HOLD'].to_i - held) / 60} 分钟"
        next
      end
      st.delete('manual_at')
      st.delete('manual_node')
    end

    # 切换判据
    # 当前节点是否"连续两次都测不通"（单次失败可能是噪声，不立刻切，避免来回抖）
    cur_recs = recent_records(rec_for(hist, turl, cur)) || []
    tail2 = cur_recs.last(2)
    cur_dead2 = tail2.size == 2 && tail2.all? { |r| r['ms'].nil? }
    best_last = last_rec(hist, turl, best)
    dead_cur = cur_dead2 && !best_last.nil? && !best_last['ms'].nil?
    need = if cur.nil? || cur_score.nil?
             true
           elsif dead_cur
             true   # 当前节点最近连续两次测不通，候选最近一次是通的 → 立刻切（不等窗口攒满）
           else
             better = cur_rank - best_rank
             better >= CONF['TOLERANCE_MS'].to_i && better >= cur_rank * CONF['TOLERANCE_PCT'].to_f / 100
           end
    unless need
      log "[select] #{g}：保持「#{cur}」(#{fmt(cur_score)})，最优「#{best}」#{fmt(bstat)} 未达切换阈值"
      next
    end

    min_interval = group_min_switch_interval(g)
    if !dead_cur && st['last_switch'] && now_t - st['last_switch'] < min_interval
      log "[select] #{g}：想切到「#{best}」但距上次切换不足 #{min_interval}s，本轮不动"
      next
    end

    verify_max = (CONF['GUARD_VERIFY_MAX'] || 6).to_i
    eligible = if dead_cur || cur.nil? || cur_score.nil?
                 scored
               else
                 scored.select do |n, s|
                   rank = candidate_rank(s, recent_records(rec_for(hist, turl, n)))
                   better = cur_rank - rank
                   better >= CONF['TOLERANCE_MS'].to_i && better >= cur_rank * CONF['TOLERANCE_PCT'].to_f / 100
                 end
               end
    chosen = nil
    tried = 0
    eligible.each do |cand, stat|
      next if cand == cur
      break if tried >= verify_max

      tried += 1
      ms = verify_switch_candidate(hist, g, cand)
      next unless ms

      chosen = [cand, stat, ms]
      break
    end
    unless chosen
      log "[select] #{g}：候选实测 #{tried} 个无人通过，保持「#{cur}」"
      next
    end
    best, bstat, verified_ms = chosen

    code, _body = api_put("/proxies/#{enc(g)}", { 'name' => best })
    if code.zero?
      log "[select] #{g}：候选实测通过 #{verified_ms}ms 后切到「#{best}」#{fmt(bstat)}（原「#{cur}」#{fmt(cur_score)}）"
      st['set'] = best
      st['last_switch'] = now_t
      st.delete('manual_at')
      st.delete('manual_node')
      switched += 1
    else
      log "[select] #{g}：切换失败 HTTP #{code}"
    end
  end
  save_json(HISTORY_FILE, hist)
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

def atomic_write_yaml(path, data)
  text = dump_yaml(data)
  YAML.unsafe_load(text)
  old = File.exist?(path) ? File.read(path) : nil
  return false if old == text

  tmp = File.join(File.dirname(path), ".#{File.basename(path)}.tmp#{Process.pid}")
  File.write(tmp, text)
  YAML.unsafe_load_file(tmp)
  File.rename(tmp, path)
  YAML.unsafe_load_file(path)
  true
ensure
  File.delete(tmp) if tmp && File.exist?(tmp)
end

def config_paths
  src = `uci -q get openclash.config.config_path 2>/dev/null`.strip
  list = []
  list << src unless src.empty?
  list << "/etc/openclash/#{File.basename(src)}" unless src.empty?
  list.select { |p| File.exist?(p) }.uniq
end

def check_smart_members
  script = '/etc/openclash/custom/oc-smart-members.rb'
  paths = config_paths
  return if !File.exist?(script) || paths.empty?

  cmd = ['ruby', script, '--check'] + paths
  out = IO.popen(cmd, err: [:child, :out], &:read)
  rc = $?.exitstatus || 1
  out.to_s.each_line { |line| log line.strip }
  log "[warn] oc-smart-members 只读校验失败（退出码 #{rc}），等待 OpenClash overwrite hook 修复" unless rc.zero?
rescue StandardError => e
  log "[warn] oc-smart-members 只读校验异常: #{e.message}"
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
        before = g.dup
        g['type'] = 'select'
        %w[url interval tolerance lazy expected-status strategy].each { |k| g.delete(k) }
        touched = true if g != before
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

    changed << path if atomic_write_yaml(path, data)
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
    lines << "history_max_age=#{CONF['HISTORY_MAX_AGE']}"
    lines << "cycle_min=#{CONF['CYCLE_MIN'] || '5'}"
    # 僵尸节点统计：让面板/日志能看出"全失败的节点占多少、这轮跳过了多少"
    if DEAD_SKIP
      dead_total = 0
      skippable = 0
      seen_nodes = {}
      nodes.each_key do |key|
        url, node = key.split('|', 2)
        next if seen_nodes[node]

        seen_nodes[node] = true
        # 只统计"该节点确实参与测速"的地址：只要在任意一个地址上还活着就不算僵尸
        # （口径与 run_cycle 的 node_fully_skippable? 一致）
        recs = (hist['by_url'] || {}).values.filter_map { |bucket| bucket[node] }
        next if recs.empty? || !recs.all? { |r| dead_node?(r) }

        dead_total += 1
        skippable += 1 if skip_dead_probe?(hist, url, node)
      end
      lines << "dead_nodes=#{dead_total}"
      lines << "skippable_nodes=#{skippable}"
    end
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
  check_smart_members
  needs = groups.select { |g| proxies[g] && proxies[g]['type'] != 'Selector' }
  log "[auto] 这些被接管的组不是 select（模型控制不了），自动转换: #{needs.join(', ')}" unless needs.empty?

  path = `uci -q get openclash.config.config_path 2>/dev/null`.strip
  rt = path.empty? ? nil : "/etc/openclash/#{File.basename(path)}"
  changed = convert_groups('convert', groups)
  return if changed.empty?

  log "[auto] 已修正配置漂移：#{changed.join(', ')}"
  return if needs.empty? || rt.nil? || !changed.include?(rt) || !File.exist?(rt)

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
  # 顺便丢掉已经空掉的测速地址桶：以前换过测速地址会留下空桶，
  # 面板上就会显示"该地址 0/0"，看起来像测速失败。
  (hist['by_url'] || {}).delete_if { |_url, bucket| bucket.nil? || bucket.empty? }
  # 清理已经不再参与测速的节点的复测时间戳，避免文件无限增长
  if hist['probe'].is_a?(Hash)
    live = {}
    (hist['by_url'] || {}).each do |url, bucket|
      bucket.each_key { |n| live["#{url}|#{n}"] = true }
    end
    hist['probe'].delete_if { |k, _v| !live[k] }
  end
  removed
end

def validate_managed_groups(groups, proxies)
  groups.each do |g|
    info = proxies[g]
    unless info && info['all']
      log "[check] #{g}: API无成员信息"
      next
    end
    members = info['all'] || []
    real_nodes = members.count { |m| node?(proxies, m) }
    missing = members.count { |m| !proxies.key?(m) && !NEVER.include?(m) }
    self_ref = members.include?(g)
    log "[check] #{g}: 总成员 #{members.size}，真实节点 #{real_nodes}，不存在成员 #{missing}#{self_ref ? '，存在自引用' : ''}"
  end
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
    mark_probe(hist, turl, cur)

    if ms.nil?
      # 单次抖动不算数：同一次 guard 里立刻复测一次，避免来回切
      ms = test_delay(cur, turl, texp, tmo)
      rec << { 't' => Time.now.to_i, 'ms' => ms }
      rec.shift while rec.size > HISTORY_N
      mark_probe(hist, turl, cur)
    end
    next if ms   # 复测通了 → 不折腾

    # 连测两次都不通：按分数取候选，**逐个实测验证**，第一个实测通的才切过去。
    # 这一步是关键：以前只按历史分数选，切过去可能又是个死节点（用户体感就是"切了还是打不开"）。
    cands = (info['all'] || [])
            .reject { |x| NEVER.include?(x) || x == cur }
            .map { |x| [x, candidate_score(proxies, hist, x, min_samples, turl)] }
            .sort_by { |x, sc| candidate_rank(sc, recent_records(rec_for(hist, turl, x))) }
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
      mark_probe(hist, turl, x)
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
      st.delete('manual_node')
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
if ENV['OC_SMART_ENTRY'] != '1' && %w[cycle select guard reset convert revert watchdog].include?(cmd)
  log "[warn] 请通过 /etc/openclash/custom/oc-smart.sh 调用 #{cmd}，直接 ruby 会绕过防重入锁"
end

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
  validate_managed_groups(groups, proxies)
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
