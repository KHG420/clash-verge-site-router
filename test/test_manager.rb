# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/verge_router/manager'

class ManagerTest < Minitest::Test
  class Bridge
    attr_reader :calls

    def initialize(triggered = false, &on_perform)
      @triggered, @on_perform, @calls = triggered, on_perform, []
    end

    def status
      { 'available' => true, 'message' => '手动完成操作' }
    end

    def perform(action, name = '')
      @calls << [action, name]
      @on_perform.call(action, name) if @on_perform
      { 'triggered' => @triggered, 'message' => '手动完成操作' }
    end
  end

  def setup
    @dir = Dir.mktmpdir('verge-manager-test-')
    @store = VergeRouter::Storage.new(@dir)
    @router = VergeRouter::Router.new(@dir)
    @catalog = {
      'current' => 'base', 'items' => [
        { 'uid' => 'merge', 'type' => 'merge', 'file' => 'merge.yaml' },
        { 'uid' => 'groups', 'type' => 'groups', 'file' => 'groups.yaml' },
        { 'uid' => 'rules', 'type' => 'rules', 'file' => 'rules.yaml' },
        { 'uid' => 'base', 'type' => 'remote', 'name' => '日常订阅', 'file' => 'base.yaml',
          'url' => 'https://base.example.test/sub?token=base-secret',
          'option' => { 'merge' => 'merge', 'groups' => 'groups', 'rules' => 'rules' } },
        { 'uid' => 'dev', 'type' => 'remote', 'name' => '开发订阅', 'file' => 'dev.yaml',
          'url' => 'https://dev.example.test/sub?token=dev-secret' },
        { 'uid' => 'spare', 'type' => 'remote', 'name' => '备用订阅', 'file' => 'spare.yaml',
          'url' => 'https://spare.example.test/sub?token=spare-secret' }
      ]
    }
    put_yaml('profiles.yaml', @catalog)
    @store.write('profiles/merge.yaml', "# original merge\nfind-process-mode: off\n")
    @store.write('profiles/groups.yaml', "prepend: []\nappend: []\ndelete: []\n")
    @store.write('profiles/rules.yaml', "prepend: []\nappend: []\ndelete: []\n")
    %w[base dev spare].each do |uid|
      put_yaml("profiles/#{uid}.yaml", 'proxies' => [
        { 'name' => '香港 A', 'type' => 'ss', 'server' => 'node.test', 'port' => 443, 'password' => 'node-secret' },
        { 'name' => '美国 B', 'type' => 'ss', 'server' => 'node.test', 'port' => 443, 'password' => 'node-secret' }
      ])
    end
    put_yaml('clash-verge.yaml', 'mode' => 'rule', 'proxy-groups' => [{ 'name' => 'Default', 'type' => 'select', 'proxies' => ['DIRECT'] }], 'rules' => ['MATCH,Default'])
    @bridge = Bridge.new
    @controller = Object.new
    @controller.define_singleton_method(:get) { |_path| raise VergeRouter::Error, '客户端尚未加载' }
    @manager = VergeRouter::Manager.new(@router, controller: @controller, bridge: @bridge, wait_seconds: 0)
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  def put_yaml(path, data)
    @store.write(path, Psych.dump(data))
  end

  def yaml(path)
    VergeRouter::YamlDocument.new(@store.read(path)).data
  end

  def file_bytes
    Dir.glob(File.join(@dir, '**', '*')).select { |path| File.file?(path) }.to_h do |path|
      [path.sub(@dir + '/', ''), File.binread(path)]
    end
  end

  def managed_provider(uid)
    "VR_#{Digest::SHA256.hexdigest(uid)[0, 12]}"
  end

  def test_overview_distinguishes_unknown_quota_spare_and_provider_references
    @catalog['items'].find { |s| s['uid'] == 'dev' }['extra'] = { 'upload' => 45, 'download' => 45, 'total' => 100, 'expire' => 1 }
    @catalog['items'].find { |s| s['uid'] == 'spare' }['extra'] = { 'total' => 0 }
    put_yaml('profiles.yaml', @catalog)
    runtime = yaml('clash-verge.yaml')
    runtime['proxy-providers'] = { 'user-dev' => { 'type' => 'http', 'url' => @catalog['items'].find { |s| s['uid'] == 'dev' }['url'] } }
    put_yaml('clash-verge.yaml', runtime)
    @manager.add('github', 'dev')
    rows = @manager.overview('providers' => { 'user-dev' => { 'proxies' => [{ 'name' => '香港 A' }] } }, 'proxies' => {})
    base, dev, spare = %w[base dev spare].map { |uid| rows.find { |r| r['uid'] == uid } }
    assert_equal '主订阅', base['role']
    assert_nil base['remaining_percent']
    assert_equal '分流使用', dev['role']
    assert_equal 10.0, dev['remaining_percent']
    assert_equal 1, dev['expires_at']
    assert_equal [{ 'name' => 'user-dev', 'updated_at' => nil, 'node_count' => 1, 'managed' => false }], dev['providers']
    assert_equal '备用', spare['role']
    assert_nil spare['remaining']
    refute @manager.alerts(rows, 100).any? { |a| a['id'] == 'spare:quota' || a['id'] == 'base:quota' }
    assert_equal 'error', @manager.alerts(rows, 100).find { |a| a['id'] == 'dev:expiry' }['level']
  end

  def test_alias_and_snapshot_never_expose_subscription_or_node_credentials
    @manager.alias_subscription('dev', '工作', ['重要', '重要'])
    @manager.add('github', '工作')
    assert_equal 'dev', @router.config['routes'].first['subscription']
    assert_equal ['重要'], @manager.metadata['tags']['dev']
    output = JSON.generate(@manager.snapshot)
    assert_includes output, '工作'
    %w[base-secret dev-secret spare-secret node-secret].each { |secret| refute_includes output, secret }
    assert_raises(VergeRouter::Error) { @manager.alias_subscription('spare', '工作') }
  end

  def test_batch_add_normalizes_urls_and_is_atomic_on_invalid_input
    result = @manager.add(['https://WWW.Example.COM:443/path?q=1', 'github'], 'dev')
    assert_equal 2, result['count']
    assert_equal ['www.example.com', 'github'], @router.config['routes'].map { |r| r['domain'] || r['site'] }
    before = @store.read(VergeRouter::Router::CONFIG)
    assert_raises(VergeRouter::Error) { @manager.add(['valid.example.com', 'https://user:pass@example.com/'], 'spare') }
    assert_equal before, @store.read(VergeRouter::Router::CONFIG)
    assert_raises(VergeRouter::Error) { @manager.add(['example.com'] * 201, 'dev') }
    assert_equal before, @store.read(VergeRouter::Router::CONFIG)
  end

  def test_toggle_excludes_disabled_route_from_plan_and_restores_it
    @manager.add('example.com', 'dev')
    @manager.toggle('example.com', false)
    assert_equal false, @manager.routes.first['enabled']
    assert_empty @router.plan.state['owned']['rules']
    @manager.toggle('example.com', true)
    assert_equal true, @manager.routes.first['enabled']
    assert_equal 1, @router.plan.state['owned']['rules'].size
    assert_raises(VergeRouter::Error) { @manager.toggle('missing.example', true) }
  end

  def test_policy_modes_and_region_filter_change_generated_group
    @manager.add('example.com', 'dev')
    { 'manual' => 'select', 'fixed' => 'select', 'auto' => 'url-test', 'fallback' => 'fallback' }.each do |mode, expected|
      values = { 'mode' => mode }
      values['node'] = '香港 A' if mode == 'fixed'
      values['regions'] = ['香港'] if mode == 'auto'
      @manager.policy('dev', values)
      plan = @router.plan
      groups_path = @router.extension_path(@router.resolve('base'), 'groups', @router.catalog)
      group = VergeRouter::YamlDocument.new(plan.changes.fetch(groups_path)).data['prepend'].first
      assert_equal expected, group['type']
      assert_match(/香港/, group['filter']) if %w[fixed auto].include?(mode)
    end
    before = @store.read(VergeRouter::Router::CONFIG)
    assert_raises(VergeRouter::Error) { @manager.policy('dev', 'mode' => 'fixed', 'node' => '不存在') }
    assert_equal before, @store.read(VergeRouter::Router::CONFIG)
    assert_raises(VergeRouter::Error) { @manager.policy('dev', 'mode' => 'auto', 'regions' => ['日本']) }
    assert_equal before, @store.read(VergeRouter::Router::CONFIG)
  end

  def test_scenario_save_and_use_replaces_mapping_without_auto_apply
    @manager.add('example.com', 'dev')
    @manager.save_scene('办公')
    @manager.add('other.example.com', 'spare')
    @manager.use_scene('办公')
    assert_equal ['example.com'], @router.config['routes'].map { |r| r['domain'] }
    assert_nil @router.state
    assert_equal 1, @manager.metadata['scenarios']['办公']['routes'].size
  end

  def test_portable_export_omits_credentials_and_import_reports_missing_bindings_without_writing
    @manager.add('example.com', 'dev')
    @manager.save_scene('办公')
    exported = @manager.export_document
    output = JSON.generate(exported)
    %w[base-secret dev-secret node-secret].each { |secret| refute_includes output, secret }
    assert_equal '开发订阅', exported['mapping']['routes'].first['subscription']
    exported['mapping']['routes'].first['subscription'] = '异地订阅'
    before = file_bytes
    result = @manager.import_document(exported)
    assert_equal false, result['ready']
    assert_equal ['异地订阅'], result['missing']
    assert_equal before, file_bytes
    assert_raises(VergeRouter::Error) { @manager.import_document(exported, {}, true) }
    assert_equal before, file_bytes
    ready = @manager.import_document(exported, { '异地订阅' => 'spare' })
    assert_equal true, ready['ready']
  end

  def test_notification_deduplicates_then_sends_again_when_alert_returns
    @catalog['items'].find { |s| s['uid'] == 'dev' }['extra'] = { 'expire' => 1 }
    put_yaml('profiles.yaml', @catalog)
    sent = []
    notifier = ->(message) { sent << message }
    assert_operator @manager.notify_alerts(notifier)['sent'], :>, 0
    assert_equal 0, @manager.notify_alerts(notifier)['sent']
    assert_equal 1, sent.size
    @catalog['items'].find { |s| s['uid'] == 'dev' }['extra'] = {}
    put_yaml('profiles.yaml', @catalog)
    @manager.notify_alerts(notifier)
    @catalog['items'].find { |s| s['uid'] == 'dev' }['extra'] = { 'expire' => 1 }
    put_yaml('profiles.yaml', @catalog)
    assert_operator @manager.notify_alerts(notifier)['sent'], :>, 0
    assert_equal 2, sent.size
  end

  def test_diagnose_extracts_url_host_and_reports_planned_and_observed_routes
    @manager.add('example.com', 'dev')
    responses = {
      '/rules' => { 'rules' => [
        { 'type' => 'RuleSet', 'payload' => 'earlier', 'proxy' => 'Other' },
        { 'type' => 'DomainSuffix', 'payload' => 'example.com', 'proxy' => 'Running Group' }
      ] },
      '/connections' => { 'connections' => [
        { 'metadata' => { 'host' => 'api.example.com' }, 'rule' => 'DomainSuffix',
          'rulePayload' => 'example.com', 'chains' => ['香港 A', 'Running Group'] },
        { 'metadata' => { 'host' => 'other.example.com' }, 'chains' => ['美国 B'] }
      ] }
    }
    @controller.define_singleton_method(:get) { |path| responses.fetch(path) }
    result = @manager.diagnose('https://API.Example.com/path?q=1')
    assert_equal 'api.example.com', result['domain']
    assert_equal '开发订阅', result['planned']['subscription']
    assert_equal 'Running Group', result['runtime']['group']
    assert_equal false, result['runtime']['certain']
    assert_equal ['香港 A'], result['observed'].map { |row| row['node'] }
    assert_empty result['warnings']
  end

  def test_deploy_reports_awaiting_client_then_verified_with_fake_runtime
    @manager.add('example.com', 'dev')
    first = @manager.deploy
    assert_equal 'awaiting_client', first['state']
    assert_equal [['reactivate', '']], @bridge.calls
    state = @router.state
    provider = state['owned']['providers'].keys.first
    group = state['owned']['groups'].keys.first
    node = "[VR:#{provider.sub('VR_', '')}] 香港 A"
    responses = {
      '/configs' => { 'mode' => 'rule' },
      '/rules' => { 'rules' => state['owned']['rules'].map { |r| t, d, g = r.split(',', 3); { 'type' => t == 'DOMAIN' ? 'Domain' : 'DomainSuffix', 'payload' => d, 'proxy' => g } } },
      '/proxies' => { 'proxies' => { group => { 'all' => [node], 'now' => node } } },
      '/providers/proxies' => { 'providers' => { provider => { 'proxies' => [{ 'name' => node }] } } }
    }
    @controller.define_singleton_method(:get) { |path| responses.fetch(path) }
    second = @manager.deploy
    assert_equal 'verified', second['state']
    assert_equal 1, second['verification']['rule_count']
    assert_equal [['reactivate', '']], @bridge.calls
  end

  def test_refresh_partial_failure_is_not_reported_as_success
    @catalog['items'].find { |s| s['uid'] == 'dev' }['updated'] = 1
    put_yaml('profiles.yaml', @catalog)
    @bridge = Bridge.new(true) do
      @catalog['items'].find { |s| s['uid'] == 'dev' }['updated'] = 2
      put_yaml('profiles.yaml', @catalog)
    end
    provider = managed_provider('dev')
    responses = { '/proxies' => { 'proxies' => {} }, '/providers/proxies' => { 'providers' => { provider => {} } } }
    @controller.define_singleton_method(:get) { |path| responses.fetch(path) }
    @controller.define_singleton_method(:refresh_provider) { |_name| raise VergeRouter::Error, 'provider failed' }
    @manager = VergeRouter::Manager.new(@router, controller: @controller, bridge: @bridge, wait_seconds: 0)
    result = @manager.refresh('dev')
    assert_equal 'partial', result['state']
    assert_equal true, result['items'].first['updated']
    assert_equal false, result['items'].first['provider_updated']
    assert_equal [['refresh', '开发订阅']], @bridge.calls
  end

  def install_adoptable_entries(shared = false)
    provider = { 'type' => 'http', 'url' => @catalog['items'].find { |s| s['uid'] == 'dev' }['url'],
                 'path' => './proxy_providers/user.yaml' }
    merge = yaml('profiles/merge.yaml')
    merge['proxy-providers'] = { 'UserProvider' => provider }
    put_yaml('profiles/merge.yaml', merge)
    groups = yaml('profiles/groups.yaml')
    groups['prepend'] = [{ 'name' => 'User Route', 'type' => 'select', 'use' => ['UserProvider'], 'proxies' => [] }]
    groups['append'] = [{ 'name' => 'Other Route', 'type' => 'select', 'use' => ['UserProvider'] }] if shared
    put_yaml('profiles/groups.yaml', groups)
    rules = yaml('profiles/rules.yaml')
    rules['prepend'] = ['DOMAIN-SUFFIX,example.com,User Route']
    put_yaml('profiles/rules.yaml', rules)
  end

  def test_adoption_preview_is_read_only_and_commit_can_restore_original_bytes
    install_adoptable_entries
    before = file_bytes
    candidates = @manager.adoptions
    assert_equal 1, candidates.size
    refute candidates.first.keys.any? { |key| key.start_with?('_') }
    preview = @manager.adopt(candidates.first['id'])
    assert_equal 'User Route', preview['group']
    assert_equal before, file_bytes
    result = @manager.adopt(candidates.first['id'], true)
    assert_equal 'awaiting_client', result['state']
    assert_equal 'dev', @router.config['routes'].first['subscription']
    assert @router.state
    @store.rollback(result['backup'])
    before.each { |path, bytes| assert_equal bytes, @store.read(path).b, path }
    assert_nil @store.read(VergeRouter::Router::CONFIG)
    assert_nil @router.state
  end

  def test_adoption_rejects_shared_provider_without_writing
    install_adoptable_entries(true)
    before = file_bytes
    assert_empty @manager.adoptions
    assert_raises(VergeRouter::Error) { @manager.adopt('missing', true) }
    assert_equal before, file_bytes
  end
end
