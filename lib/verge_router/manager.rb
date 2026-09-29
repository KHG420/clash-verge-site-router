# frozen_string_literal: true

require_relative 'router'
require_relative 'controller'
require_relative 'client_bridge'

module VergeRouter
  class Manager
    META = 'verge-router/manager.json'
    DEFAULT_ALERTS = { 'expiry_days' => 7, 'remaining_percent' => 10, 'stale_days' => 7 }.freeze
    attr_reader :router

    def initialize(router, controller: nil, bridge: nil, wait_seconds: 30)
      @router, @controller = router, controller
      @bridge = bridge || ClientBridge.new(@router.storage.root)
      @wait_seconds = wait_seconds
    end

    def api
      @controller || Controller.new(@router.storage)
    end

    def metadata
      raw = @router.storage.read(META)
      data = raw ? JSON.parse(raw) : {}
      raise Error, '管理偏好格式错误' unless data.is_a?(Hash) && (!data['version'] || data['version'] == 1)
      { 'version' => 1, 'aliases' => {}, 'tags' => {}, 'scenarios' => {}, 'alerts' => DEFAULT_ALERTS.dup }.merge(data)
    rescue JSON::ParserError
      raise Error, '管理偏好 JSON 已损坏'
    end

    def edit_metadata
      @router.storage.locked do
        data = metadata
        yield data
        @router.storage.write(META, JSON.pretty_generate(data) + "\n")
      end
    end

    def resolve(reference)
      aliases = metadata['aliases'].select { |_uid, value| value == reference }.keys
      raise Error, '别名重复，请使用订阅 UID' if aliases.size > 1
      @router.resolve(aliases.first || reference)
    end

    def edit_mapping
      @router.storage.locked do
        @router.storage.check_pending!
        data = @router.config
        yield data
        @router.plan(data) # Validate the whole intent before saving any part of it.
        @router.save_config(data)
      end
    end

    def routes
      @router.config['routes'].map do |row|
        name = begin
          @router.resolve(row['subscription'])['name']
        rescue Error
          '订阅已不存在'
        end
        row.merge('enabled' => row['enabled'] != false, 'subscription_name' => name)
      end
    end

    def add(sites, target, exact = false)
      uid = resolve(target)['uid']
      entries = Array(sites).map do |text|
        key = Router.site_key(text)
        if Router.presets.key?(key) && !exact
          { 'site' => key, 'subscription' => uid }
        else
          { 'domain' => Router.domain(key), 'exact' => exact, 'subscription' => uid }
        end
      end
      raise Error, '请输入至少一个网站' if entries.empty?
      raise Error, '单次最多添加 200 个网站' if entries.size > 200
      edit_mapping do |data|
        entries.each do |entry|
          data['routes'].reject! { |r| (r['site'] || r['domain']) == (entry['site'] || entry['domain']) }
          data['routes'] << entry
        end
      end
      { 'message' => '映射已保存，应用后生效。', 'count' => entries.size }
    end

    def toggle(site, enabled)
      raise Error, '启用状态必须是布尔值' unless [true, false].include?(enabled)
      key = Router.site_key(site)
      edit_mapping do |data|
        row = data['routes'].find { |r| (r['site'] || r['domain']) == key }
        raise Error, '找不到这个网站映射' unless row
        row['enabled'] = enabled
      end
      { 'message' => enabled ? '映射已恢复，应用后生效。' : '映射已停用，应用后生效。' }
    end

    def policy(target, values)
      uid = resolve(target)['uid']
      policy = values.select { |k, _| %w[mode node regions].include?(k) }
      probe = @router.config.merge('policies' => { uid => policy })
      @router.validate_config(probe)
      source = @router.storage.read(@router.profile_path(resolve(uid)))
      available = source ? Array(YamlDocument.new(source).data['proxies']).map { |node| node['name'] } : []
      regions = policy.fetch('regions', [])
      available.select! { |name| regions.any? { |r| name.downcase.include?(r.downcase) } } unless regions.empty?
      available.select! { |name| name == policy['node'] } if policy['mode'] == 'fixed'
      raise Error, '节点偏好没有匹配节点，请刷新订阅或调整筛选。' if available.empty?
      edit_mapping { |data| (data['policies'] ||= {})[uid] = policy }
      { 'message' => '节点偏好已保存，应用后生效。' }
    end

    def alias_subscription(target, name, tags = [])
      uid = resolve(target)['uid']
      raise Error, '别名最多 60 字，不能包含网址或控制字符' unless name.is_a?(String) && name.size <= 60 && !name.match?(/[\x00-\x1f]|:\/\//)
      raise Error, '标签必须是最多 10 个短文本' unless tags.is_a?(Array) && tags.size <= 10 && tags.all? { |t| t.is_a?(String) && t.size <= 30 && !t.match?(/[\x00-\x1f]|:\/\//) }
      edit_metadata do |meta|
        clash = @router.subscriptions.any? { |s| s['uid'] != uid && s['name'] == name }
        clash ||= meta['aliases'].any? { |key, value| key != uid && value == name && !name.empty? }
        raise Error, '别名与其他订阅重名' if clash
        meta['aliases'][uid], meta['tags'][uid] = name, tags.uniq
      end
      { 'message' => '本地别名和标签已保存，客户端原始名称保持不变。' }
    end

    def runtime
      {
        'proxies' => api.get('/proxies').fetch('proxies'),
        'providers' => api.get('/providers/proxies').fetch('providers')
      }
    rescue Error, KeyError => e
      { 'proxies' => {}, 'providers' => {}, 'error' => e.is_a?(Error) ? e.message : '控制器数据不完整' }
    end

    def overview(live = runtime)
      c, meta, assignments = @router.catalog, metadata, routes
      runtime_yaml = YamlDocument.new(@router.storage.read('clash-verge.yaml') || '{}').data
      definitions = runtime_yaml.fetch('proxy-providers', {})
      c['items'].select { |item| %w[remote local].include?(item['type']) }.map do |item|
        uid, extra = item['uid'], item['extra'].is_a?(Hash) ? item['extra'] : {}
        raw = @router.storage.read(@router.profile_path(item))
        count = begin
          raw ? Array(YamlDocument.new(raw).data['proxies']).size : 0
        rescue Error
          0
        end
        used = numeric(extra['upload']) && numeric(extra['download']) ? extra['upload'] + extra['download'] : nil
        total = numeric(extra['total'])
        total = nil if total && total <= 0
        remaining = used && total ? [total - used, 0].max : nil
        matched = definitions.select { |_name, definition| definition.is_a?(Hash) && item['url'] && definition['url'] == item['url'] }.keys
        managed_name = "VR_#{Digest::SHA256.hexdigest(uid)[0, 12]}"
        matched << managed_name if live['providers'].key?(managed_name)
        providers = matched.uniq.map do |name|
          actual = live['providers'][name] || {}
          { 'name' => name, 'updated_at' => actual['updatedAt'], 'node_count' => actual['proxies'].is_a?(Array) ? actual['proxies'].size : nil, 'managed' => name == managed_name }
        end
        own_sites = assignments.select { |row| row['subscription'] == uid && row['enabled'] }.map { |row| row['site'] || row['domain'] }
        runtime_groups = Array(runtime_yaml['proxy-groups']).select { |group| (Array(group['use']) & matched).any? }.map { |group| group['name'] }
        domain_rules = Array(runtime_yaml['rules']).select { |rule| rule.is_a?(String) }.map { |rule| rule.split(',') }.select do |parts|
          %w[DOMAIN DOMAIN-SUFFIX].include?(parts[0]) && runtime_groups.include?(parts[2])
        end.map { |parts| parts.first(2) }
        inferred_sites = []
        Router.presets.each do |key, definition|
          expected = definition['domains'].map { |d| ['DOMAIN-SUFFIX', d] } + definition.fetch('exact_domains', []).map { |d| ['DOMAIN', d] }
          if (expected - domain_rules).empty?
            inferred_sites << key
            domain_rules -= expected
          end
        end
        inferred_sites.concat(domain_rules.map(&:last))
        warnings = []
        warnings << '本地节点缓存为空或不可读' if count.zero?
        warnings << '运行集合尚未加载' if !own_sites.empty? && providers.none? { |p| p['node_count'] && p['node_count'] > 0 }
        { 'uid' => uid, 'name' => item['name'], 'alias' => meta['aliases'][uid], 'tags' => meta['tags'][uid] || [],
          'active' => c['current'] == uid, 'type' => item['type'],
          'role' => c['current'] == uid ? '主订阅' : (!providers.empty? || !own_sites.empty? ? '分流使用' : '备用'),
          'used' => used, 'total' => total, 'remaining' => remaining, 'remaining_percent' => remaining && (remaining * 100.0 / total).round(1),
          'expires_at' => positive_time(extra['expire']), 'updated_at' => positive_time(item['updated']),
          'node_count' => count, 'sites' => (own_sites + inferred_sites).uniq, 'providers' => providers, 'warnings' => warnings }
      end
    end

    def numeric(value)
      value.is_a?(Numeric) && value.finite? && value >= 0 ? value : nil
    end

    def positive_time(value)
      number = numeric(value)
      number && number > 0 ? number : nil
    end

    def alerts(rows = overview, now = Time.now.to_i)
      settings = DEFAULT_ALERTS.merge(metadata['alerts'])
      rows.flat_map do |row|
        list = []
        if row['expires_at'] && row['expires_at'] <= now + settings['expiry_days'] * 86_400
          expired = row['expires_at'] <= now
          list << ['expiry', expired ? 'error' : 'warning', expired ? '订阅已到期' : "订阅将在 #{((row['expires_at'] - now) / 86_400.0).ceil} 天内到期"]
        end
        if row['remaining_percent'] && row['remaining_percent'] <= settings['remaining_percent']
          list << ['quota', 'warning', "剩余流量 #{row['remaining_percent']}%"]
        end
        if row['updated_at'] && row['updated_at'] < now - settings['stale_days'] * 86_400
          list << ['stale', 'warning', '订阅资料长期未刷新，请核对流量和到期信息']
        end
        row['warnings'].each_with_index { |warning, index| list << ["config#{index}", 'warning', warning] }
        list.map { |kind, level, message| { 'id' => "#{row['uid']}:#{kind}", 'level' => level, 'subscription' => row['name'], 'message' => message } }
      end
    end

    def alert_values(values)
      raise Error, '提醒设置必须是对象' unless values.is_a?(Hash) && (values.keys - DEFAULT_ALERTS.keys).empty?
      settings = DEFAULT_ALERTS.merge(values.select { |k, _| DEFAULT_ALERTS.key?(k) })
      raise Error, '提醒阈值超出范围' unless settings.all? { |key, value| value.is_a?(Numeric) && value.finite? && value >= 0 && value <= (key == 'remaining_percent' ? 100 : 365) }
      settings
    end

    def configure_alerts(values)
      settings = alert_values(values)
      edit_metadata { |meta| meta['alerts'] = settings }
      { 'message' => '提醒阈值已保存。' }
    end

    def status
      state = @router.state
      return { 'state' => 'unmanaged', 'label' => '尚未应用', 'message' => '保存映射后预览并应用，也可以接管已有分流。' } unless state
      plan = @router.plan
      if state['mapping_hash'] != Router.fingerprint(@router.config) || plan.changes.any? { |path, bytes| @router.storage.read(path) != bytes }
        return { 'state' => 'pending', 'label' => '待应用', 'message' => '映射、订阅或节点偏好已有变更。' }
      end
      @router.verify(api)
      { 'state' => 'verified', 'label' => '已生效', 'message' => '运行规则和所选节点来源已核验。' }
    rescue Error => e
      { 'state' => 'attention', 'label' => '需要处理', 'message' => e.message }
    end

    def plan
      result = @router.plan
      { 'base_name' => result.base_name, 'summary' => result.summary, 'rule_count' => result.state['owned']['rules'].size,
        'changed_files' => result.changes.keys.select { |path| @router.storage.read(path) != result.changes[path] }, 'seed_count' => result.seeds.size }
    end

    def snapshot
      live = runtime
      rows = overview(live)
      base = @router.resolve(@router.config['base_profile'])
      meta = metadata
      { 'version' => '0.2.0', 'base' => base.select { |k, _| %w[uid name].include?(k) }, 'subscriptions' => rows,
        'routes' => routes, 'status' => status, 'scenarios' => meta['scenarios'].map { |name, mapping| { 'name' => name, 'route_count' => mapping['routes'].size } },
        'alerts' => alerts(rows), 'alert_settings' => DEFAULT_ALERTS.merge(meta['alerts']),
        'presets' => Router.presets.map { |id, preset| { 'id' => id, 'description' => preset['description'] } },
        'backups' => @router.storage.backups.map { |id| @router.storage.manifest(id).select { |k, _| %w[status created_at].include?(k) }.merge('id' => id) },
        'adoptions' => adoptions, 'integration' => @bridge.status, 'runtime_error' => live['error'] }
    end

    def deploy
      id, = @router.apply
      begin
        verified = @router.verify(api)
        return { 'state' => 'verified', 'message' => '配置已生效并通过核验。', 'backup' => id, 'verification' => verified }
      rescue Error
        # Saved extensions are authoritative. The client must regenerate runtime.
      end
      triggered = @bridge.perform('reactivate')
      return { 'state' => 'awaiting_client', 'message' => triggered['message'] + ' 请重新激活订阅后点击核验。', 'backup' => id } unless triggered['triggered']
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @wait_seconds
      begin
        result = @router.verify(api)
        { 'state' => 'verified', 'message' => '客户端已重新激活，运行配置核验通过。', 'backup' => id, 'verification' => result }
      rescue Error => e
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          sleep 0.4
          retry
        end
        { 'state' => 'awaiting_client', 'message' => e.message, 'backup' => id }
      end
    end

    def refresh(target = 'all')
      chosen = target == 'all' ? @router.subscriptions.select { |s| s['type'] == 'remote' } : [resolve(target)]
      raise Error, '只能刷新远程订阅' if chosen.any? { |s| s['type'] != 'remote' }
      before = @router.catalog['items'].to_h { |item| [item['uid'], item['updated']] }
      if target != 'all' && @router.subscriptions.count { |s| s['name'] == chosen.first['name'] } > 1
        raise Error, '客户端存在重名订阅，请先在客户端改名再单独刷新'
      end
      trigger = @bridge.perform(target == 'all' ? 'refresh_all' : 'refresh', target == 'all' ? '' : chosen.first['name'])
      unless trigger['triggered']
        return { 'state' => 'awaiting_client', 'message' => trigger['message'] + ' 请在客户端完成刷新，再重新读取状态。' }
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @wait_seconds
      loop do
        current = @router.catalog['items'].to_h { |item| [item['uid'], item['updated']] }
        break if chosen.all? { |s| current[s['uid']] != before[s['uid']] }
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.4
      end
      current = @router.catalog['items'].to_h { |item| [item['uid'], item['updated']] }
      providers = runtime['providers']
      items = chosen.map do |subscription|
        updated = current[subscription['uid']] != before[subscription['uid']]
        row = { 'subscription' => subscription['name'], 'updated' => updated, 'provider_updated' => nil }
        provider_name = "VR_#{Digest::SHA256.hexdigest(subscription['uid'])[0, 12]}"
        if updated && providers.key?(provider_name)
          begin
            old_provider_hash = @router.state && @router.state['owned']['providers'][provider_name]
            next_provider_hash = @router.plan.state['owned'].fetch('providers', {})[provider_name]
            if old_provider_hash && old_provider_hash != next_provider_hash
              raise Error, '订阅链接或集合设置已改变，请先预览并应用；运行集合暂时保留旧节点。'
            end
            api.refresh_provider(provider_name)
            row['provider_updated'] = true
          rescue Error => e
            row['provider_updated'], row['message'] = false, e.message
          end
        end
        row['message'] ||= updated ? '订阅资料已更新。' : '未观察到更新成功；旧配置保留，可稍后检查客户端结果。'
        row
      end
      result_state = items.all? { |row| row['updated'] && row['provider_updated'] != false } ? 'refreshed' : 'partial'
      { 'state' => result_state, 'message' => result_state == 'refreshed' ? '所选订阅刷新完成。' : '部分订阅尚未确认更新，请查看逐项结果。', 'items' => items }
    end

    def nodes(target)
      sub, live = resolve(target), runtime
      uid = sub['uid']
      token = Digest::SHA256.hexdigest(uid)[0, 12]
      runtime_yaml = YamlDocument.new(@router.storage.read('clash-verge.yaml') || '{}').data
      definitions = runtime_yaml.fetch('proxy-providers', {})
      provider_name = "VR_#{token}"
      unless live['providers'].key?(provider_name)
        matches = definitions.select { |_name, definition| sub['url'] && definition['url'] == sub['url'] }.keys
        provider_name = matches.first if matches.size == 1
      end
      provider = live['providers'][provider_name] || {}
      prefix = provider_name == "VR_#{token}" ? "[VR:#{token}] " : definitions.fetch(provider_name, {}).fetch('override', {}).fetch('additional-prefix', '')
      by_name = Array(provider['proxies']).to_h { |node| [node['name'].delete_prefix(prefix), node] }
      raw = @router.storage.read(@router.profile_path(sub))
      source = raw ? Array(YamlDocument.new(raw).data['proxies']) : []
      group = live['proxies'].find { |name, _| name.start_with?('网站分流 · ') && name.end_with?(token[0, 6]) }
      unless group
        definition = Array(runtime_yaml['proxy-groups']).find { |entry| Array(entry['use']).include?(provider_name) }
        group = [definition['name'], live['proxies'][definition['name']]] if definition && live['proxies'][definition['name']]
      end
      { 'subscription' => sub['name'], 'policy' => @router.config.fetch('policies', {}).fetch(uid, { 'mode' => 'manual' }),
        'group' => group && group[0], 'selected' => group && group[1]['now'],
        'nodes' => source.map do |node|
          running = by_name[node['name']] || {}
          { 'name' => node['name'], 'live_name' => running['name'], 'alive' => running['alive'], 'delay' => Array(running['history']).last.to_h['delay'] }
        end }
    end

    def scene_name(name)
      raise Error, '场景名称需要 1–60 字，不能包含网址或控制字符' unless name.is_a?(String) && (1..60).cover?(name.size) && !name.match?(/[\x00-\x1f]|:\/\//)
      name
    end

    def save_scene(name)
      name = scene_name(name)
      @router.plan
      edit_metadata { |meta| meta['scenarios'][name] = @router.config }
      { 'message' => "场景 #{name} 已保存。" }
    end

    def preview_scene(name)
      mapping = metadata['scenarios'][scene_name(name)]
      raise Error, '场景不存在' unless mapping
      planned = @router.plan(mapping)
      { 'mapping' => portable_mapping(mapping), 'plan' => { 'summary' => planned.summary,
        'rule_count' => planned.state['owned']['rules'].size,
        'changed_files' => planned.changes.keys.select { |path| @router.storage.read(path) != planned.changes[path] } } }
    end

    def use_scene(name, apply = false)
      mapping = metadata['scenarios'][scene_name(name)]
      raise Error, '场景不存在' unless mapping
      edit_mapping { |data| data.replace(mapping) }
      apply ? deploy : { 'message' => '场景已载入，应用后生效。' }
    end

    def delete_scene(name)
      edit_metadata { |meta| raise Error, '场景不存在' unless meta['scenarios'].delete(scene_name(name)) }
      { 'message' => '场景已删除。' }
    end

    def portable_mapping(mapping)
      names = @router.subscriptions.group_by { |s| s['name'] }
      refs = ([mapping['base_profile']] + mapping['routes'].map { |r| r['subscription'] } + mapping.fetch('policies', {}).keys).uniq
      translated = refs.to_h do |ref|
        item = @router.resolve(ref)
        raise Error, '存在重名订阅，请在客户端改名后导出' if names[item['name']].size > 1
        [ref, item['name']]
      end
      copy = JSON.parse(JSON.generate(mapping))
      copy['base_profile'] = translated.fetch(mapping['base_profile'])
      copy['routes'].each { |r| r['subscription'] = translated.fetch(r['subscription']) }
      copy['policies'] = copy.fetch('policies', {}).to_h { |uid, value| [translated.fetch(uid), value] }
      copy
    end

    def export_document
      { 'format' => 'verge-router-portable', 'version' => 1, 'mapping' => portable_mapping(@router.config),
        'scenarios' => metadata['scenarios'].transform_values { |mapping| portable_mapping(mapping) }, 'alerts' => metadata['alerts'] }
    end

    def import_document(document, bindings = {}, commit = false)
      unless document.is_a?(Hash) && document['format'] == 'verge-router-portable' && document['version'] == 1 &&
        (document.keys - %w[format version mapping scenarios alerts]).empty?
        raise Error, '不是受支持的无凭证导出文件'
      end
      raise Error, '订阅绑定必须是对象' unless bindings.is_a?(Hash)
      raise Error, '场景列表格式错误' unless document.fetch('scenarios', {}).is_a?(Hash)
      imported_alerts = document['alerts'] && alert_values(document['alerts'])
      # Rebuild only the supported schema; never store arbitrary imported data.
      missing = []
      transform = lambda do |mapping|
        raise Error, '导入映射格式错误' unless mapping.is_a?(Hash) && mapping['version'] == 1 && mapping['routes'].is_a?(Array)
        @router.validate_config(mapping)
        result = JSON.parse(JSON.generate(mapping))
        translate = lambda do |ref|
          raise Error, '订阅引用格式错误' unless ref.is_a?(String) && !ref.match?(/:\/\//)
          begin
            resolve(bindings.fetch(ref, ref))['uid']
          rescue Error
            missing << ref
            ref
          end
        end
        result['base_profile'] = translate.call(mapping['base_profile'])
        result['routes'].each { |r| raise Error, '导入规则格式错误' unless r.is_a?(Hash); r['subscription'] = translate.call(r['subscription']) }
        result['policies'] = result.fetch('policies', {}).to_h { |key, val| [translate.call(key), val] }
        result
      end
      mapping = transform.call(document['mapping'])
      scenarios = document.fetch('scenarios', {}).to_h { |name, value| [scene_name(name), transform.call(value)] }
      result = { 'routes' => mapping['routes'], 'missing' => missing.uniq, 'ready' => missing.empty? }
      if missing.empty?
        @router.plan(mapping)
        scenarios.each_value { |value| @router.plan(value) }
      end
      if commit
        raise Error, '请先绑定所有缺失的订阅' unless missing.empty?
        raise Error, '导入请使用默认映射文件，暂不支持 --config。' if @router.instance_variable_get(:@config_path)
        @router.storage.locked do
          @router.plan(mapping)
          before = [Router::CONFIG, META].to_h { |path| [path, Storage.hash(@router.storage.read(path))] }
          meta = metadata
          meta['scenarios'].merge!(scenarios)
          meta['alerts'] = imported_alerts if imported_alerts
          @router.storage.transaction({ Router::CONFIG => JSON.pretty_generate(mapping) + "\n", META => JSON.pretty_generate(meta) + "\n" }, before)
        end
        result['message'] = '规则与场景已导入，应用后生效。'
      end
      result
    end
  end
end

require_relative 'diagnostics'
require_relative 'adoption'
