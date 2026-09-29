# frozen_string_literal: true

require 'uri'
require_relative 'yaml_document'
require_relative 'storage'

module VergeRouter
  Plan = Struct.new(:changes, :seeds, :expected, :guards, :state, :summary, :base_name, keyword_init: true)

  class Router
    STATE = 'verge-router/state.json'
    CONFIG = 'verge-router/routes.json'
    attr_reader :storage

    def self.default_directory
      if RUBY_PLATFORM.include?('darwin')
        File.expand_path('~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev')
      elsif RUBY_PLATFORM.match?(/mswin|mingw/)
        File.join(ENV.fetch('APPDATA', ''), 'io.github.clash-verge-rev.clash-verge-rev')
      else
        File.join(ENV.fetch('XDG_CONFIG_HOME', File.expand_path('~/.config')), 'io.github.clash-verge-rev.clash-verge-rev')
      end
    end

    def initialize(directory, config_path = nil)
      @storage = Storage.new(directory)
      @config_path = config_path && File.expand_path(config_path)
    end

    def catalog(raw = @storage.read('profiles.yaml'))
      raise Error, '数据目录中没有 profiles.yaml' unless raw
      data = YamlDocument.new(raw, 'profiles.yaml').data
      raise Error, 'profiles.yaml 缺少 items 列表' unless data['items'].is_a?(Array)
      data
    end

    def subscriptions
      c = catalog
      c['items'].select { |i| %w[remote local].include?(i['type']) }.map do |item|
        { 'uid' => item['uid'], 'name' => item['name'], 'type' => item['type'], 'active' => item['uid'] == c['current'] }
      end
    end

    def resolve(reference, c = catalog)
      items = c['items'].select { |i| %w[remote local].include?(i['type']) }
      matches = items.select { |i| i['uid'] == reference }
      matches = items.select { |i| i['name'] == reference } if matches.empty?
      raise Error, '订阅不存在，请运行 subscriptions 查看可用名称和 UID' if matches.empty?
      raise Error, '订阅名称重复，请改用 UID' if matches.size > 1
      matches.first
    end

    def config
      raw = @config_path ? (File.file?(@config_path) && File.read(@config_path)) : @storage.read(CONFIG)
      return { 'version' => 1, 'base_profile' => catalog['current'], 'routes' => [] } unless raw
      data = JSON.parse(raw)
      unless data.is_a?(Hash) && data['version'] == 1 && data['routes'].is_a?(Array) && data['base_profile'].is_a?(String)
        raise Error, '网站映射必须包含 version: 1、base_profile 和 routes 列表'
      end
      validate_config(data)
      data
    rescue JSON::ParserError
      raise Error, '网站映射 JSON 语法错误（已隐藏原始内容）'
    end

    def validate_config(data)
      unless data.is_a?(Hash) && data['version'] == 1 && data['routes'].is_a?(Array) && data['base_profile'].is_a?(String)
        raise Error, '网站映射必须包含 version: 1、base_profile 和 routes 列表'
      end
      raise Error, '网站映射含未知顶层字段' unless (data.keys - %w[version base_profile routes policies]).empty?
      raise Error, '节点偏好必须是对象' if data.key?('policies') && !data['policies'].is_a?(Hash)
      data.fetch('policies', {}).each do |uid, policy|
        raise Error, '节点偏好格式错误' unless uid.is_a?(String) && policy.is_a?(Hash) &&
          (policy.keys - %w[mode node regions]).empty? && %w[manual fixed auto fallback].include?(policy['mode'])
        raise Error, '固定节点需要节点名称' if policy['mode'] == 'fixed' && (!policy['node'].is_a?(String) || policy['node'].empty?)
        raise Error, '地区筛选需要文字列表' if policy.key?('regions') && (!policy['regions'].is_a?(Array) ||
          policy['regions'].any? { |r| !r.is_a?(String) || r.empty? || r.size > 80 } || policy['regions'].size > 20)
      end
      data
    end

    def save_config(data)
      bytes = JSON.pretty_generate(data) + "\n"
      if @config_path
        raise Error, '拒绝覆盖符号链接形式的映射文件' if File.symlink?(@config_path)
        parent = File.dirname(@config_path)
        FileUtils.mkdir_p(parent, mode: 0o700)
        temp = "#{@config_path}.#{SecureRandom.hex(6)}.tmp"
        begin
          File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(bytes); f.flush; f.fsync }
          File.rename(temp, @config_path)
        ensure
          File.unlink(temp) if File.exist?(temp)
        end
      else
        @storage.write(CONFIG, bytes)
      end
    end

    def self.presets
      JSON.parse(File.read(File.expand_path('../../presets.json', __dir__)))
    end

    def self.domain(value)
      raise Error, '请输入域名字符串' unless value.is_a?(String)
      name = value.downcase.sub(/\.\z/, '')
      labels = name.split('.', -1)
      valid = name.bytesize <= 253 && labels.size >= 2 && labels.all? do |part|
        part.bytesize <= 63 && part.match?(/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/)
      end
      raise Error, '请输入域名，不要包含协议、路径、端口、通配符或 IP；国际化域名请用 Punycode' unless valid && !name.match?(/\A[0-9.]+\z/)
      name
    end

    def self.site_key(value)
      text = value.to_s.strip
      if text.match?(%r{\Ahttps?://}i)
        uri = URI.parse(text)
        raise Error, '网址不能包含登录凭证' if uri.userinfo
        text = uri.host
      end
      presets.key?(text) ? text : domain(text)
    rescue URI::InvalidURIError
      raise Error, '网址格式错误'
    end

    def add(site, target, exact = false)
      site = self.class.site_key(site)
      @storage.locked do
        data = config
        subscription = resolve(target)
        entry = if self.class.presets.key?(site) && !exact
                  { 'site' => site, 'subscription' => subscription['uid'] }
                else
                  { 'domain' => self.class.domain(site), 'exact' => exact, 'subscription' => subscription['uid'] }
                end
        key = entry['site'] || entry['domain']
        data['routes'].reject! { |r| (r['site'] || r['domain']) == key }
        data['routes'] << entry
        save_config(data)
      end
    end

    def remove(site)
      @storage.locked do
        data = config
        key = self.class.site_key(site)
        count = data['routes'].size
        data['routes'].reject! { |r| (r['site'] || r['domain']) == key }
        raise Error, '映射中没有这个网站' if count == data['routes'].size
        save_config(data)
      end
    end

    def state(raw = @storage.read(STATE))
      return nil unless raw
      data = JSON.parse(raw)
      unless data.is_a?(Hash) && data['version'] == 1 && data['owned'].is_a?(Hash) &&
             data['owned']['providers'].is_a?(Hash) && data['owned']['groups'].is_a?(Hash) && data['owned']['rules'].is_a?(Array)
        raise Error, '工具状态文件格式不支持或已损坏'
      end
      data
    rescue JSON::ParserError
      raise Error, '工具状态文件 JSON 已损坏'
    end

    def self.fingerprint(value)
      # Mapping order is not semantically significant.
      canonical = lambda do |v|
        case v
        when Hash then v.keys.sort.to_h { |k| [k, canonical.call(v[k])] }
        when Array then v.map { |x| canonical.call(x) }
        else v
        end
      end
      Digest::SHA256.hexdigest(JSON.generate(canonical.call(value)))
    end

    def profile_path(item)
      file = item.fetch('file')
      raise Error, '订阅文件名不安全' unless file.is_a?(String) && file.match?(/\A[A-Za-z0-9_.-]+\.yaml\z/)
      "profiles/#{file}"
    end

    def extension_path(base, kind, c)
      uid = base.fetch('option', {})[kind]
      item = c['items'].find { |i| i['uid'] == uid && i['type'] == kind }
      raise Error, "当前订阅缺少 #{kind} 扩展，请在 Clash Verge 中初始化该订阅的扩展" unless item
      relative = profile_path(item)
      raise Error, '扩展文件不存在' unless @storage.read(relative)
      other = c['items'].any? { |i| i['uid'] != base['uid'] && i.fetch('option', {}).value?(uid) }
      raise Error, '扩展被多个订阅共用，拒绝修改共享扩展' if other
      relative
    end

    def remove_owned(documents, owned)
      merge, groups, rules = documents
      providers = merge.ensure_map('proxy-providers')
      owned.fetch('providers').each do |name, hash|
        node = merge.get(name, providers)
        raise Error, '工具管理的代理集合已被外部修改，拒绝覆盖' unless node && self.class.fingerprint(YamlDocument.decode(node)) == hash
        merge.delete(name, providers)
      end
      list = groups.ensure_sequence('prepend').children
      owned.fetch('groups').each do |name, hash|
        index = list.index { |n| YamlDocument.decode(n).is_a?(Hash) && YamlDocument.decode(n)['name'] == name }
        raise Error, '工具管理的策略组已被外部修改，拒绝覆盖' unless index && self.class.fingerprint(YamlDocument.decode(list[index])) == hash
        list.delete_at(index)
      end
      list = rules.ensure_sequence('prepend').children
      owned.fetch('rules').each do |rule|
        index = list.index { |n| YamlDocument.decode(n) == rule }
        raise Error, '工具管理的规则已被外部修改，拒绝覆盖' unless index
        list.delete_at(index)
      end
    end

    def plan(mapping_override = nil, ownership_override = nil)
      @storage.check_pending!
      catalog_bytes = @storage.read('profiles.yaml')
      c = catalog(catalog_bytes)
      mapping = validate_config(mapping_override || config)
      base = resolve(mapping['base_profile'], c)
      raise Error, '请先在 Clash Verge 中激活映射所指定的主订阅' unless base['uid'] == c['current']
      state_bytes = @storage.read(STATE)
      old = ownership_override || state(state_bytes)
      raise Error, '已有其他主订阅的管理状态，请先回滚旧配置' if old && old['base_uid'] != base['uid']
      if mapping['routes'].empty? && old.nil?
        return Plan.new(changes: {}, seeds: {}, expected: {}, guards: {},
                        state: { 'owned' => { 'rules' => [] } }, summary: [], base_name: base['name'])
      end
      paths = %w[merge groups rules].map { |kind| extension_path(base, kind, c) }
      raise Error, '扩展文件不能共用同一个路径' unless paths.uniq.size == 3
      originals = paths.to_h { |p| [p, @storage.read(p)] }
      documents = paths.map { |p| YamlDocument.new(originals[p], File.basename(p)) }
      merge, groups, rules = documents
      remove_owned(documents, old['owned']) if old
      providers_node = merge.ensure_map('proxy-providers')
      group_nodes = groups.ensure_sequence('prepend').children
      rule_nodes = rules.ensure_sequence('prepend').children
      runtime = @storage.read('clash-verge.yaml')
      runtime_data = runtime ? YamlDocument.new(runtime, '运行配置').data : {}
      if runtime_data['mode'] && runtime_data['mode'] != 'rule'
        raise Error, '网站分流需要规则模式，请先在 Clash Verge 中切换到规则模式'
      end
      if (runtime_data['proxy-groups'] || []).any? { |g| g['include-all'] == true || g['include-all-providers'] == true }
        raise Error, '现有策略组会自动包含所有代理集合，新增订阅可能影响其他网站；请先将这些组改为明确的 proxies/use'
      end
      targets = {}
      normalized_rules = {}
      summary = []
      guards = { 'profiles.yaml' => Storage.hash(catalog_bytes) }
      guards['clash-verge.yaml'] = Storage.hash(runtime) if runtime
      mapping['routes'].each do |route|
        unless route.is_a?(Hash) && (route.keys - %w[site domain exact subscription enabled]).empty? &&
               route['subscription'].is_a?(String) && (!!route['site'] ^ !!route['domain']) &&
               (!route.key?('exact') || [true, false].include?(route['exact'])) &&
               (!route.key?('enabled') || [true, false].include?(route['enabled']))
          raise Error, '每条映射需要 subscription 和 site/domain 其中之一；exact 必须是布尔值'
        end
        next if route['enabled'] == false
        target = resolve(route['subscription'], c)
        raise Error, '目标订阅需要是远程订阅，才能自动更新代理集合' unless target['type'] == 'remote'
        targets[target['uid']] = target
        entries = if route['site']
                    preset = self.class.presets[route['site']]
                    raise Error, '未知网站预设，请运行 presets 查看' unless preset
                    raise Error, '网站预设不能设置 exact' if route.key?('exact')
                    preset['domains'].map { |v| ['DOMAIN-SUFFIX', self.class.domain(v)] } +
                      preset.fetch('exact_domains', []).map { |v| ['DOMAIN', self.class.domain(v)] }
                  else
                    [[route['exact'] ? 'DOMAIN' : 'DOMAIN-SUFFIX', self.class.domain(route['domain'])]]
                  end
        entries.each do |type, domain|
          key = [type, domain]
          raise Error, '同一个域名被绑定到多个订阅，请消除冲突' if normalized_rules[key] && normalized_rules[key] != target['uid']
          normalized_rules[key] = target['uid']
        end
        summary << { 'site' => route['site'] || route['domain'], 'subscription' => target['name'], 'rules' => entries.size }
      end
      providers = {}
      new_groups = []
      seeds = {}
      group_names = {}
      targets.sort.each do |uid, target|
        token = Digest::SHA256.hexdigest(uid)[0, 12]
        provider_name = "VR_#{token}"
        group_name = "网站分流 · #{target['name']} · #{token[0, 6]}"
        raise Error, '订阅名称包含规则不支持的逗号或换行' if group_name.match?(/[,\r\n]/)
        url = target['url']
        begin
          uri = URI.parse(url.to_s)
          raise URI::InvalidURIError unless %w[http https].include?(uri.scheme) && uri.host && !url.match?(/[\r\n]/)
        rescue URI::InvalidURIError
          raise Error, '目标订阅 URL 不是有效的 HTTP/HTTPS 地址'
        end
        ua = target.fetch('option', {})['user_agent'] || 'clash-verge'
        raise Error, '订阅 User-Agent 格式不正确' unless ua.is_a?(String) && !ua.match?(/[\r\n]/)
        cache_path = "proxy_providers/verge-router/#{token}.yaml"
        provider = { 'type' => 'http', 'url' => url, 'path' => "./#{cache_path}", 'interval' => 86_400,
                     'proxy' => 'DIRECT', 'header' => { 'User-Agent' => [ua] },
                     'health-check' => { 'enable' => true, 'url' => 'https://www.gstatic.com/generate_204',
                                         'interval' => 600, 'timeout' => 5000, 'lazy' => true },
                     'override' => { 'additional-prefix' => "[VR:#{token}] " } }
        raise Error, '代理集合名称与现有配置冲突' if merge.get(provider_name, providers_node)
        existing_groups = group_nodes.map { |n| YamlDocument.decode(n) } + (runtime_data['proxy-groups'] || [])
        if existing_groups.any? { |g| g.is_a?(Hash) && g['name'] == group_name } && !(old && old['owned']['groups'].key?(group_name))
          raise Error, '策略组名称与现有配置冲突'
        end
        providers[provider_name] = provider
        group_names[uid] = group_name
        source_path = profile_path(target)
        source = @storage.read(source_path)
        raise Error, '目标订阅没有本地缓存，请先在 Clash Verge 更新它' unless source
        nodes = YamlDocument.new(source, '目标订阅缓存').data['proxies']
        raise Error, '目标订阅缓存没有节点列表，不支持仅引用外部 providers 的订阅' unless nodes.is_a?(Array) && !nodes.empty?
        policy = mapping.fetch('policies', {})[uid] || { 'mode' => 'manual' }
        members = nodes.map { |node| node['name'] }.compact
        regions = policy.fetch('regions', [])
        members.select! { |name| regions.any? { |r| name.downcase.include?(r.downcase) } } unless regions.empty?
        members.select! { |name| name == policy['node'] } if policy['mode'] == 'fixed'
        raise Error, '节点偏好没有匹配节点，请重新选择固定节点或地区' if members.empty?
        group = { 'name' => group_name, 'type' => { 'auto' => 'url-test', 'fallback' => 'fallback' }.fetch(policy['mode'], 'select'), 'use' => [provider_name] }
        if policy['mode'] == 'fixed'
          group['filter'] = '^' + Regexp.escape("[VR:#{token}] #{policy['node']}") + '$'
        elsif !regions.empty?
          group['filter'] = '(?i)(' + regions.map { |r| Regexp.escape(r) }.join('|') + ')'
        end
        if %w[auto fallback].include?(policy['mode'])
          group.merge!('url' => 'https://www.gstatic.com/generate_204', 'interval' => 600, 'lazy' => true)
          group['tolerance'] = 80 if policy['mode'] == 'auto'
        end
        new_groups << group
        seeds[cache_path] = source unless @storage.read(cache_path)
        guards[source_path] = Storage.hash(source)
      end
      providers.each { |name, provider| merge.put(name, provider, providers_node) }
      group_nodes.unshift(*new_groups.map { |g| YamlDocument.node(g) })
      # Specific subdomains take priority over a parent-domain mapping.
      additions = normalized_rules.sort_by { |(type, domain), _| [-domain.split('.').size, type == 'DOMAIN' ? 0 : 1, domain] }.map do |(type, domain), uid|
        "#{type},#{domain},#{group_names.fetch(uid)}"
      end
      rule_nodes.unshift(*additions.map { |r| YamlDocument.node(r) })
      owned = { 'providers' => providers.transform_values { |v| self.class.fingerprint(v) },
                'groups' => new_groups.to_h { |g| [g['name'], self.class.fingerprint(g)] }, 'rules' => additions }
      new_state = { 'version' => 1, 'base_uid' => base['uid'], 'owned' => owned,
                    'mapping_hash' => self.class.fingerprint(mapping) }
      changes = paths.zip(documents.map(&:dump)).to_h
      changes[STATE] = JSON.pretty_generate(new_state) + "\n"
      expected = originals.transform_values { |bytes| Storage.hash(bytes) }
      expected[STATE] = Storage.hash(state_bytes)
      changes.each_value.with_index { |text, i| YamlDocument.new(text) if i < 3 }
      Plan.new(changes: changes, seeds: seeds, expected: expected, guards: guards,
               state: new_state, summary: summary, base_name: base['name'])
    end

    def apply
      @storage.locked do
        result = plan
        if result.state['mapping_hash'] && result.state['mapping_hash'] != self.class.fingerprint(config)
          raise Error, '网站映射在规划后已改变，请重新执行'
        end
        # Cached subscription text stays in the application data directory.
        # Keep caches on rollback: the core may have refreshed them independently.
        result.seeds.each { |path, bytes| @storage.write(path, bytes) unless @storage.read(path) }
        [@storage.transaction(result.changes, result.expected, result.guards), result]
      end
    end
  end
end
