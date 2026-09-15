#!/usr/bin/env ruby
# frozen_string_literal: true
#
# oc_mrs_slim.rb —— 用 guize 的 .mrs 规则集替换 OpenClash 配置里的内联 rules，实现配置瘦身
#
# 用法:  ruby /etc/openclash/custom/oc_mrs_slim.rb <clash配置文件.yaml> [--dry-run] [--strict] [--force]
#
# 做的事:
#   1. 为 7 个分类写入 rule-providers (type: http + format: mrs，本地缓存到 ./rule_provider/*.mrs)
#   2. 删除内联 rules 中可被 .mrs 覆盖的 DOMAIN / DOMAIN-SUFFIX / IP-CIDR / IP-CIDR6 规则
#      （只删目标策略组属于这 7 个分类的规则）
#   3. 在原位置插入 RULE-SET 规则，保持原有分流优先级
#   4. 若缺少分类对应的策略组（例如“开发平台”），自动从“国外媒体”复制一个 select 组出来
#
# --strict（也支持环境变量 OC_MRS_STRICT=1）：
#   让 rules 里**只剩**这 13 条 RULE-SET + OpenClash 自己的 SRC-IP-CIDR + MATCH 兜底，
#   把 DOMAIN-KEYWORD / PROCESS-NAME / GEOIP / 自定义规则全部丢掉。
#   （mrs 只能装 DOMAIN/DOMAIN-SUFFIX/IP-CIDR，这些类型本来就放不进 .mrs）
#
# 幂等：重复执行不会重复插入，可安全地放在 openclash_custom_overwrite.sh 里每次启动都跑。

require 'yaml'

CONFIG = ARGV[0]
DRY_RUN = ARGV.include?('--dry-run')
STRICT = ARGV.include?('--strict') || ENV['OC_MRS_STRICT'] == '1'
FORCE = ARGV.include?('--force') || ENV['OC_MRS_FORCE'] == '1'
abort "usage: #{$PROGRAM_NAME} <config.yaml> [--dry-run] [--strict] [--force]" if CONFIG.nil? || CONFIG.empty?
abort "file not found: #{CONFIG}" unless File.exist?(CONFIG)

# Psych/libyaml 只把 3 字节 UTF-8（≤ U+FFFF，例如 Ⓜ️）原样输出，
# 4 字节的（≥ U+10000，例如 🤖🎥📲）会写成 \U0001F916，看起来像"两种写法"。
# 这里统一还原成 UTF-8，让配置文件里所有分组名写法一致。
FOUR_BYTE_ESCAPE = /\\U(0001[0-9A-Fa-f]{4})/.freeze

def dump_yaml(data)
  YAML.dump(data).gsub(FOUR_BYTE_ESCAPE) { [Regexp.last_match(1).hex].pack('U') }
end

RELEASE = 'https://github.com/aoxijy/guize/releases/latest/download'

# 分类 => [中文名(用于匹配/新建策略组), 拥有的 mrs 类型]；顺序 = RULE-SET 顺序 = 分流优先级
CATEGORIES = {
  'ai-platform'        => ['AI平台',   %w[domain ipcidr]],
  'reject'             => ['全球拦截', %w[domain]],
  'social-chat'        => ['社交聊天', %w[domain ipcidr]],
  'developer-platform' => ['开发平台', %w[domain ipcidr]],
  'microsoft-apple'    => ['微软苹果', %w[domain ipcidr]],
  'foreign-media'      => ['国外媒体', %w[domain ipcidr]],
  'direct'             => ['全球直连', %w[domain ipcidr]]
}.freeze

EMOJI = {
  'AI平台' => '🤖', '社交聊天' => '📲', '开发平台' => '💻', '国外媒体' => '🎥',
  '微软苹果' => 'Ⓜ️', '全球直连' => '🎯', '全球拦截' => '🛑'
}.freeze

DOMAIN_TYPES = %w[DOMAIN DOMAIN-SUFFIX].freeze
IP_TYPES     = %w[IP-CIDR IP-CIDR6].freeze
# 这些类型 mrs 装不下，非严格模式保留在主配置里
KEEP_TYPES   = %w[DOMAIN-KEYWORD PROCESS-NAME PROCESS-PATH GEOIP GEOSITE IP-ASN
                  SRC-IP-CIDR DST-PORT SRC-PORT RULE-SET MATCH].freeze
# 严格模式只保留这些（OpenClash 自己的本机直连 + MATCH 兜底）
STRICT_KEEP_TYPES = %w[SRC-IP-CIDR SRC-IP-CIDR6 DST-PORT SRC-PORT MATCH].freeze

def load_yaml(path)
  YAML.unsafe_load_file(path)
rescue NoMethodError, ArgumentError
  YAML.load_file(path)
end

def rule_fields(rule)
  rule.to_s.split(',').map(&:strip)
end

# 取规则的目标策略（最后一段；跳过 no-resolve / src 修饰符）
def rule_target(parts)
  return nil if parts.length < 2

  last = parts[-1].to_s
  last = parts[-2].to_s if %w[no-resolve src].include?(last)
  last
end

data = load_yaml(CONFIG)
abort '[oc-mrs-slim] not a valid clash config' unless data.is_a?(Hash)

groups = (data['proxy-groups'] ||= [])
rules  = (data['rules'] ||= [])
provider_names = CATEGORIES.flat_map { |cat, (_l, kinds)| kinds.map { |k| "#{cat}-#{k}" } }
rules_before = rules.dup
changed = false

# ---- 1. 定位 / 补齐策略组 ------------------------------------------------
targets = {}
CATEGORIES.each do |cat, (label, _kinds)|
  group = groups.find { |g| g.is_a?(Hash) && g['name'].to_s.include?(label) }
  if group.nil?
    template = groups.find { |g| g.is_a?(Hash) && g['name'].to_s.include?('国外媒体') } ||
               groups.find { |g| g.is_a?(Hash) && g['type'].to_s == 'select' && g['proxies'].is_a?(Array) }
    members = template && template['proxies'].is_a?(Array) ? template['proxies'].dup : %w[♻️ 自动选择 DIRECT]
    name = "#{EMOJI[label]} #{label}"
    group = { 'name' => name, 'type' => 'select', 'proxies' => members }
    idx = template ? groups.index(template) : groups.length
    groups.insert(idx || groups.length, group)
    changed = true
    puts "[oc-mrs-slim] 新建策略组 #{name}（成员 #{members.length} 个，模板 #{template ? template['name'] : 'fallback'}）"
  end
  targets[cat] = group['name']
end

covered = targets.values.uniq

# ---- 2. 删除可被 .mrs 覆盖的内联规则 -------------------------------------
insert_at = nil
kept = []
dropped = Hash.new(0)
rules.each do |rule|
  parts = rule_fields(rule)
  type = parts[0].to_s.upcase
  if type == 'RULE-SET' && provider_names.include?(parts[1].to_s)
    insert_at ||= kept.length
    next
  end
  if STRICT
    # 严格模式：只留 OpenClash 自己的本机直连规则和 MATCH 兜底，其余全部丢掉
    if STRICT_KEEP_TYPES.include?(type)
      kept << rule
    else
      insert_at ||= kept.length
      dropped[type] += 1
    end
    next
  end
  if (DOMAIN_TYPES.include?(type) || IP_TYPES.include?(type)) && covered.include?(rule_target(parts))
    insert_at ||= kept.length
    next
  end
  kept << rule
end

# ---- 3. 生成并插入 RULE-SET ---------------------------------------------
new_rules = CATEGORIES.flat_map do |cat, (_l, kinds)|
  kinds.map do |kind|
    line = "RULE-SET,#{cat}-#{kind},#{targets[cat]}"
    line += ',no-resolve' if kind == 'ipcidr'
    line
  end
end

if insert_at.nil?
  insert_at = kept.index { |r| KEEP_TYPES.include?(rule_fields(r)[0].to_s.upcase) } || kept.length
end
kept.insert(insert_at, *new_rules)
data['rules'] = kept
changed = true if kept != rules_before

# ---- 4. rule-providers ---------------------------------------------------
providers = (data['rule-providers'] ||= {})
CATEGORIES.each do |cat, (_l, kinds)|
  kinds.each do |kind|
    name = "#{cat}-#{kind}"
    desired = {
      'type'     => 'http',
      'behavior' => kind,
      'format'   => 'mrs',
      'url'      => "#{RELEASE}/#{name}.mrs",
      'path'     => "./rule_provider/#{name}.mrs",
      'interval' => 86_400
    }
    next if providers[name] == desired

    providers[name] = desired
    changed = true
  end
end

removed = rules.length - (kept.length - new_rules.length)
puts "[oc-mrs-slim] #{STRICT ? '严格模式' : '常规模式'} rules: #{rules.length} -> #{kept.length}（删除内联 #{removed}，新增 RULE-SET #{new_rules.length}）"
puts '[oc-mrs-slim] rule-providers: ' + provider_names.length.to_s + ' 个 mrs（其余内置 provider 保留）'
puts '[oc-mrs-slim] 分流顺序: ' + new_rules.map { |r| r.split(',')[2] }.uniq.join(' -> ')
unless dropped.empty?
  puts '[oc-mrs-slim] 严格模式丢弃: ' + dropped.sort_by { |_k, v| -v }.map { |k, v| "#{k} #{v}" }.join(', ')
end

if DRY_RUN
  puts "[oc-mrs-slim] dry-run，未写回 #{CONFIG}"
elsif changed || FORCE
  File.write(CONFIG, dump_yaml(data))
  puts "[oc-mrs-slim] 已写回 #{CONFIG}（#{File.size(CONFIG)} bytes）"
else
  # 已经瘦过，但文件里还留着 Psych 的 4 字节 emoji 转义时，顺手统一成 UTF-8
  need_normalize = begin
    File.read(CONFIG).match?(FOUR_BYTE_ESCAPE)
  rescue StandardError
    false
  end
  if need_normalize
    File.write(CONFIG, dump_yaml(data))
    puts "[oc-mrs-slim] 已统一 #{CONFIG} 的 emoji 写法（\\U0001Fxxx -> UTF-8）"
  else
    puts "[oc-mrs-slim] #{CONFIG} 已是 mrs 版，无需改动"
  end
end
