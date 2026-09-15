#!/bin/sh
# oc-patch-yamlrb.sh —— 让 OpenClash 自己生成的配置也用 UTF-8 写 emoji
#
# 背景：OpenClash 生成运行配置时用 Ruby Psych 回写 YAML，而 Psych/libyaml 只把
#       3 字节 UTF-8（Ⓜ️ 等 U+FFFF 以下）原样输出，4 字节的（🤖🎥📲🎯🛑🐟）会写成
#       \U0001F916 转义，于是同一个文件里出现"两种写法"。内容完全等价，但看起来别扭。
#
# 做法：给 /usr/share/openclash/YAML.rb 的 dump 加一层后处理，把 4 字节 emoji 还原成 UTF-8。
#       幂等，可重复执行；OpenClash 升级覆盖该文件后重跑一次即可。
#       撤销：cp /usr/share/openclash/YAML.rb.bak.<时间戳> /usr/share/openclash/YAML.rb

F=/usr/share/openclash/YAML.rb
MARK='fix_unicode_escapes'

[ -f "$F" ] || { echo "not found: $F" >&2; exit 1; }

if grep -q "$MARK" "$F"; then
  echo "[oc-patch-yamlrb] 已打过补丁，跳过"
  exit 0
fi

cp -f "$F" "$F.bak.$(date +%Y%m%d%H%M%S)"

# 1) 在 alias original_dump 之后，再存一个指向真正 Psych 实现的别名
awk '{print} /alias_method :original_dump, :dump/ && !done {print "\t\talias_method :psych_dump, :dump"; done=1}' "$F" > "$F.new" \
  && mv "$F.new" "$F"

# 2) 追加覆写：original_dump 统一走 UTF-8 后处理
cat >> "$F" <<'RUBY'

module YAML
	# 4 字节 emoji（U+10000~U+1FFFF）Psych 会写成 \U0001F916，这里统一还原成 UTF-8。
	# 只是序列化写法变化，字符串内容完全等价。
	def self.fix_unicode_escapes(yaml_content)
		return yaml_content unless yaml_content.is_a?(String) && yaml_content.include?('\\U')
		yaml_content.gsub(/\\U(0001[0-9A-Fa-f]{4})/) { [Regexp.last_match(1).hex].pack('U') }
	rescue StandardError
		yaml_content
	end

	def self.original_dump(obj, io = nil, **options)
		content = fix_unicode_escapes(psych_dump(obj, **options))
		if io.nil?
			content
		elsif io.respond_to?(:write)
			io.write(content)
			io
		else
			content
		end
	end
end
RUBY

if ruby -c "$F" >/dev/null 2>&1; then
  echo "[oc-patch-yamlrb] 补丁完成，语法 OK"
else
  echo "[oc-patch-yamlrb] 语法检查失败，正在回滚" >&2
  cp -f "$(ls -t "$F".bak.* | head -1)" "$F"
  exit 1
fi
