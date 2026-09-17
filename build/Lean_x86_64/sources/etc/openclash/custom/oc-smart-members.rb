#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'
require 'digest'

FIXED_GROUPS = [
  '♻️ 自动选择',
  '♻️ 香港自动',
  '♻️ 亚洲自动',
  '♻️ 美国自动',
  '♻️ 其他自动',
  '🕸️ CHATGPT自动'
].freeze
AUTO_ALL = '♻️ 自动选择'
AUTO_HK = '♻️ 香港自动'
AUTO_ASIA = '♻️ 亚洲自动'
AUTO_US = '♻️ 美国自动'
AUTO_OTHER = '♻️ 其他自动'
AUTO_CHATGPT = '🕸️ CHATGPT自动'
URL_TEST_KEYS = %w[url interval tolerance lazy expected-status strategy].freeze

class MemberSyncError < StandardError; end

Options = Struct.new(:mode, :paths, keyword_init: true)

def usage
  warn 'usage: oc-smart-members.rb [--check|--dry-run] YAML...'
  exit 2
end

def parse_args(argv)
  mode = :write
  paths = []
  argv.each do |arg|
    case arg
    when '--check'
      mode = :check
    when '--dry-run'
      mode = :dry_run
    when '-h', '--help'
      usage
    else
      paths << arg
    end
  end
  usage if paths.empty?
  Options.new(mode: mode, paths: paths.uniq)
end

def load_yaml_file(path)
  data = YAML.unsafe_load_file(path)
  raise MemberSyncError, 'top-level is not a map' unless data.is_a?(Hash)
  data
rescue Psych::SyntaxError => e
  raise MemberSyncError, "YAML parse failed: #{e.message.lines.first.to_s.strip}"
rescue Errno::ENOENT
  raise MemberSyncError, 'file not found'
end

def proxy_names(data)
  proxies = data['proxies']
  raise MemberSyncError, 'proxies is empty or missing' unless proxies.is_a?(Array) && !proxies.empty?

  names = []
  blank = 0
  proxies.each do |p|
    next unless p.is_a?(Hash)
    name = p['name']
    if name.to_s.empty?
      blank += 1
      next
    end
    names << name.to_s
  end
  raise MemberSyncError, "blank proxy names: #{blank}" if blank.positive?
  raise MemberSyncError, 'no proxy names found' if names.empty?

  dup_count = names.tally.count { |_n, c| c > 1 }
  raise MemberSyncError, "duplicate proxy names: #{dup_count}" if dup_count.positive?
  names
end

def group_index(data)
  groups = data['proxy-groups']
  raise MemberSyncError, 'proxy-groups is empty or missing' unless groups.is_a?(Array) && !groups.empty?

  idx = {}
  groups.each_with_index do |g, i|
    next unless g.is_a?(Hash)
    name = g['name'].to_s
    next if name.empty?
    idx[name] = [g, i]
  end
  missing = FIXED_GROUPS.reject { |g| idx.key?(g) }
  raise MemberSyncError, "missing fixed groups: #{missing.size}" unless missing.empty?
  idx
end

def wanted_members(names)
  hk = names.select { |n| n.include?('香港') }
  asia = names.select { |n| n.include?('亚洲') && !n.include?('香港') }
  us = names.select { |n| n.include?('美国') }
  special = (hk + asia + us).uniq
  other = names.reject { |n| special.include?(n) }
  chatgpt = names.reject { |n| n.include?('香港') }

  regions = [hk, asia, us, other]
  union = regions.flatten
  raise MemberSyncError, 'region union does not cover all proxies' unless union.size == names.size && union.uniq.sort == names.uniq.sort
  raise MemberSyncError, 'region groups are not mutually exclusive' unless regions.sum(&:size) == union.uniq.size

  result = {
    AUTO_ALL => names,
    AUTO_HK => hk,
    AUTO_ASIA => asia,
    AUTO_US => us,
    AUTO_OTHER => other,
    AUTO_CHATGPT => chatgpt
  }
  empty = result.select { |_g, m| m.empty? }.keys
  raise MemberSyncError, "empty result groups: #{empty.size}" unless empty.empty?
  result
end

def sanitize_group!(group, members)
  before = Marshal.load(Marshal.dump(group))
  group['type'] = 'select'
  group['proxies'] = members.dup
  URL_TEST_KEYS.each { |k| group.delete(k) }
  group != before
end

def validate_structure!(data, expected, original_group_order)
  idx = group_index(data)
  order = data['proxy-groups'].map { |g| g.is_a?(Hash) ? g['name'].to_s : nil }
  raise MemberSyncError, 'proxy-groups order changed' unless order == original_group_order
  expected.each do |name, members|
    group = idx[name][0]
    raise MemberSyncError, "#{name} type is not select" unless group['type'].to_s.downcase == 'select'
    raise MemberSyncError, "#{name} members mismatch" unless group['proxies'] == members
    URL_TEST_KEYS.each do |k|
      raise MemberSyncError, "#{name} still has #{k}" if group.key?(k)
    end
  end
end

def dump_yaml(data)
  YAML.dump(data).gsub(/\\U(0001[0-9A-Fa-f]{4})/) { [Regexp.last_match(1).hex].pack('U') }
end

def process_one(path, mode)
  data = load_yaml_file(path)
  names = proxy_names(data)
  idx = group_index(data)
  original_group_order = data['proxy-groups'].map { |g| g.is_a?(Hash) ? g['name'].to_s : nil }
  expected = wanted_members(names)
  rules_before = data.key?('rules') ? Digest::SHA256.hexdigest(Marshal.dump(data['rules'])) : nil

  changed = false
  expected.each do |group_name, members|
    changed = true if sanitize_group!(idx[group_name][0], members)
  end

  rules_after = data.key?('rules') ? Digest::SHA256.hexdigest(Marshal.dump(data['rules'])) : nil
  raise MemberSyncError, 'rules changed in memory' unless rules_before == rules_after
  validate_structure!(data, expected, original_group_order)

  counts = FIXED_GROUPS.map { |g| "#{g}=#{expected[g].size}" }.join(' ')
  status = changed ? 'changed' : 'unchanged'
  puts "[oc-smart-members] #{File.basename(path)} #{status} #{counts} exceptions=0"

  return changed if mode == :check || mode == :dry_run || !changed

  text = dump_yaml(data)
  YAML.unsafe_load(text)
  dir = File.dirname(path)
  tmp = File.join(dir, ".#{File.basename(path)}.members.tmp#{Process.pid}")
  begin
    File.write(tmp, text)
    reparsed = load_yaml_file(tmp)
    validate_structure!(reparsed, expected, original_group_order)
    reparsed_rules = reparsed.key?('rules') ? Digest::SHA256.hexdigest(Marshal.dump(reparsed['rules'])) : nil
    raise MemberSyncError, 'rules changed after serialization' unless reparsed_rules == rules_before
    File.rename(tmp, path)
  ensure
    File.delete(tmp) if File.exist?(tmp)
  end
  true
end

opts = parse_args(ARGV)
failures = 0
changed_any = false
opts.paths.each do |path|
  begin
    changed_any = true if process_one(path, opts.mode)
  rescue StandardError => e
    failures += 1
    warn "[oc-smart-members] #{File.basename(path)} failed: #{e.message} exceptions=1"
  end
end
exit 1 if failures.positive?
exit(changed_any ? 10 : 0) if opts.mode == :dry_run
exit 0
