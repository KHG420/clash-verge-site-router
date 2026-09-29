# frozen_string_literal: true

module VergeRouter
  class Manager
    def adoption_candidates
      c = @router.catalog
      base = @router.resolve(@router.config['base_profile'], c)
      return [] unless base['uid'] == c['current']
      docs = %w[merge groups rules].map { |kind| YamlDocument.new(@router.storage.read(@router.extension_path(base, kind, c))).data }
      merge, groups, rules = docs
      providers = merge.fetch('proxy-providers', {})
      owned = @router.state
      live = runtime
      all_groups = Array(groups['prepend']) + Array(groups['append'])
      all_rules = Array(rules['prepend']) + Array(rules['append'])
      all_groups.map do |group|
        next unless group.is_a?(Hash) && group['type'] == 'select' && Array(group['use']).size == 1 && Array(group['proxies']).empty?
        name, provider_name = group['name'], group['use'].first
        next if owned && owned['owned']['groups'].key?(name)
        provider = providers[provider_name]
        next unless provider.is_a?(Hash) && provider['type'] == 'http'
        next unless (provider.fetch('override', {}).keys - ['additional-prefix']).empty?
        next unless (group.keys - %w[name type use proxies icon]).empty?
        matches = c['items'].select { |sub| sub['type'] == 'remote' && sub['url'] == provider['url'] }
        next unless matches.size == 1
        next unless Array(groups['prepend']).include?(group)
        next if all_groups.any? { |other| other != group && (Array(other['use']).include?(provider_name) || Array(other['proxies']).include?(name)) }
        matching_rules = all_rules.select { |rule| rule.is_a?(String) && rule.split(',')[2] == name }
        next if matching_rules.empty? || matching_rules.any? { |r| !%w[DOMAIN DOMAIN-SUFFIX].include?(r.split(',')[0]) || r.split(',').size != 3 || !Array(rules['prepend']).include?(r) }
        # A runtime reference outside these domain rules makes removal unsafe.
        runtime_yaml = YamlDocument.new(@router.storage.read('clash-verge.yaml') || '{}').data
        next if Array(runtime_yaml['proxy-groups']).any? { |g| g['name'] != name && (Array(g['use']).include?(provider_name) || Array(g['proxies']).include?(name)) }
        next if Array(runtime_yaml['rules']).any? { |r| r.is_a?(String) && r.split(',').include?(name) && !matching_rules.include?(r) }
        subscription = matches.first
        selection = live['proxies'].fetch(name, {})['now']
        prefix = provider.fetch('override', {}).fetch('additional-prefix', '')
        selection = selection.delete_prefix(prefix) if selection && !prefix.empty?
        hash = Router.fingerprint([group, provider, matching_rules])
        { 'id' => hash[0, 20], 'group' => name, 'subscription' => subscription['uid'], 'subscription_name' => subscription['name'],
          'rule_count' => matching_rules.size, 'sites' => matching_rules.map { |r| r.split(',')[1] }, 'selected_node' => selection,
          '_group' => group, '_provider_name' => provider_name, '_provider' => provider, '_rules' => matching_rules }
      end.compact
    rescue Error
      []
    end

    def adoptions
      adoption_candidates.map { |row| row.reject { |key, _| key.start_with?('_') } }
    end

    def adopt(id, commit = false)
      original_mapping = @router.storage.read(Router::CONFIG)
      candidate = adoption_candidates.find { |row| row['id'] == id }
      raise Error, '可接管条目已改变或无法安全接管，请重新预览。' unless candidate
      mapping = @router.config
      base = @router.resolve(mapping['base_profile'])
      ownership = @router.state || { 'version' => 1, 'base_uid' => base['uid'], 'owned' => { 'providers' => {}, 'groups' => {}, 'rules' => [] } }
      ownership['owned']['providers'][candidate['_provider_name']] = Router.fingerprint(candidate['_provider'])
      ownership['owned']['groups'][candidate['group']] = Router.fingerprint(candidate['_group'])
      ownership['owned']['rules'].concat(candidate['_rules'])
      pairs = candidate['_rules'].map { |r| r.split(',').first(2) }
      preset = Router.presets.find do |_key, definition|
        expected = definition['domains'].map { |d| ['DOMAIN-SUFFIX', d] } + definition.fetch('exact_domains', []).map { |d| ['DOMAIN', d] }
        expected.sort == pairs.sort
      end
      additions = if preset
                    [{ 'site' => preset[0], 'subscription' => candidate['subscription'] }]
                  else
                    pairs.map { |type, domain| { 'domain' => domain, 'exact' => type == 'DOMAIN', 'subscription' => candidate['subscription'] } }
                  end
      additions.each do |row|
        key = row['site'] || row['domain']
        existing = mapping['routes'].find { |r| (r['site'] || r['domain']) == key }
        raise Error, '已有同名网站映射，请先处理冲突再接管。' if existing && existing != row
        mapping['routes'] << row unless existing
      end
      raw = @router.storage.read(@router.profile_path(@router.resolve(candidate['subscription'])))
      source_names = Array(YamlDocument.new(raw).data['proxies']).map { |node| node['name'] }
      if source_names.include?(candidate['selected_node'])
        (mapping['policies'] ||= {})[candidate['subscription']] ||= { 'mode' => 'fixed', 'node' => candidate['selected_node'] }
      end
      result = @router.plan(mapping, ownership)
      summary = { 'message' => '接管会替换这组手工条目，保留其他规则；原文件进入备份。',
                  'group' => candidate['group'], 'subscription' => candidate['subscription_name'], 'rules' => candidate['rule_count'],
                  'routes' => additions, 'selected_node' => candidate['selected_node'], 'changed_files' => result.changes.keys }
      return summary unless commit
      raise Error, '接管请使用默认映射文件，暂不支持 --config。' if @router.instance_variable_get(:@config_path)
      @router.storage.locked do
        # The ownership override is only planning input; commit the final state,
        # new mapping and extension files together, covered by one rollback.
        result.changes[Router::CONFIG] = JSON.pretty_generate(mapping) + "\n"
        result.expected[Router::CONFIG] = Storage.hash(original_mapping)
        result.seeds.each { |path, bytes| @router.storage.write(path, bytes) unless @router.storage.read(path) }
        backup = @router.storage.transaction(result.changes, result.expected, result.guards)
        summary.merge('state' => 'awaiting_client', 'backup' => backup, 'message' => '已接管并备份。点击应用与核验，让客户端重新激活配置。')
      end
    end
  end
end
