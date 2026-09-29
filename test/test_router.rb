# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'stringio'
require 'open3'
require_relative '../lib/verge_router/cli'

class RouterTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('verge-router-test-')
    @store = VergeRouter::Storage.new(@dir)
    @router = VergeRouter::Router.new(@dir)
    @catalog = {
      'current' => 'base',
      'items' => [
        { 'uid' => 'merge', 'type' => 'merge', 'file' => 'merge.yaml' },
        { 'uid' => 'groups', 'type' => 'groups', 'file' => 'groups.yaml' },
        { 'uid' => 'rules', 'type' => 'rules', 'file' => 'rules.yaml' },
        { 'uid' => 'base', 'type' => 'remote', 'name' => '日常订阅', 'file' => 'base.yaml',
          'url' => 'https://base.example.test/sub?token=fixture-base-token',
          'option' => { 'merge' => 'merge', 'groups' => 'groups', 'rules' => 'rules' } },
        { 'uid' => 'dev', 'type' => 'remote', 'name' => '开发订阅', 'file' => 'dev.yaml',
          'url' => 'https://sub.example.test/sub?token=fixture-dev-token', 'option' => { 'user_agent' => 'fixture-agent' } },
        { 'uid' => 'backup', 'type' => 'remote', 'name' => '备用订阅', 'file' => 'backup.yaml',
          'url' => 'https://other.example.test/sub?token=fixture-other-token' }
      ]
    }
    put_yaml('profiles.yaml', @catalog)
    @merge = "# User comment\nfind-process-mode: off\nunrelated: &list [on, yes, true]\nalias: *list\n"
    @store.write('profiles/merge.yaml', @merge)
    put_yaml('profiles/groups.yaml', { 'prepend' => [{ 'name' => 'User Group', 'type' => 'select', 'proxies' => ['DIRECT'] }], 'append' => [], 'delete' => [] })
    put_yaml('profiles/rules.yaml', { 'prepend' => ['DOMAIN-SUFFIX,existing.example,Default'], 'append' => [], 'delete' => [] })
    nodes = { 'proxies' => [{ 'name' => 'Fixture Node', 'type' => 'anytls', 'server' => 'node.example.test', 'port' => 443, 'password' => 'fixture-password' }] }
    %w[base dev backup].each { |name| put_yaml("profiles/#{name}.yaml", nodes) }
    put_yaml('clash-verge.yaml', { 'mode' => 'rule', 'proxy-groups' => [{ 'name' => 'Default', 'type' => 'select', 'proxies' => ['DIRECT'] }], 'rules' => ['MATCH,Default'] })
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def put_yaml(path, data)
    @store.write(path, Psych.dump(data))
  end

  def yaml(path)
    VergeRouter::YamlDocument.new(@store.read(path)).data
  end

  def snapshot
    Dir.glob(File.join(@dir, '**', '*')).select { |p| File.file?(p) }.to_h { |p| [p, File.binread(p)] }
  end

  def cli(*args)
    output = StringIO.new
    errors = StringIO.new
    code = VergeRouter::CLI.run(args + ['--data-dir', @dir], out: output, err: errors)
    [code, output.string, errors.string]
  end

  def test_plan_is_read_only_and_does_not_expose_credentials
    @router.add('github', '开发订阅')
    before = snapshot
    code, output, errors = cli('plan')
    assert_equal 0, code, errors
    assert_includes output, '42'
    refute_includes output, 'fixture-dev-token'
    refute_includes output, 'fixture-password'
    assert_equal before, snapshot
  end

  def test_empty_mapping_does_not_rewrite_extensions
    before = %w[merge groups rules].to_h { |n| [n, @store.read("profiles/#{n}.yaml")] }
    assert_empty @router.plan.changes
    id, = @router.apply
    assert_nil id
    assert_nil @router.state
    before.each { |n, bytes| assert_equal bytes, @store.read("profiles/#{n}.yaml") }
  end

  def test_latest_backup_refers_to_latest_write_not_random_id_order
    @router.add('github', 'dev')
    @router.apply
    first = @store.read('profiles/rules.yaml')
    @router.add('example.com', 'backup')
    latest, = @router.apply
    assert_equal latest, @store.rollback
    assert_equal first, @store.read('profiles/rules.yaml')
  end

  def test_apply_preserves_user_rules_groups_and_yaml_scalar_semantics
    @router.add('github', '开发订阅')
    id, plan = @router.apply
    assert id
    rules = yaml('profiles/rules.yaml')
    assert_equal 43, rules['prepend'].size
    assert_equal 'DOMAIN-SUFFIX,existing.example,Default', rules['prepend'].last
    assert_equal 'User Group', yaml('profiles/groups.yaml')['prepend'].last['name']
    merge = yaml('profiles/merge.yaml')
    assert_equal 'off', merge['find-process-mode']
    assert_equal ['on', 'yes', true], merge['unrelated']
    assert_equal merge['unrelated'], merge['alias']
    provider = merge['proxy-providers'].values.first
    assert_equal 'https://sub.example.test/sub?token=fixture-dev-token', provider['url']
    assert_equal ['fixture-agent'], provider['header']['User-Agent']
    assert_equal @store.read('profiles/dev.yaml'), @store.read(plan.seeds.keys.first)
    assert_equal 0o600, File.stat(@store.path('profiles/merge.yaml')).mode & 0o777
    assert_equal 0o700, File.stat(@store.path('verge-router/backups')).mode & 0o777
  end

  def test_apply_is_idempotent_and_does_not_overwrite_refreshed_cache
    @router.add('github', 'dev')
    _, plan = @router.apply
    @store.write(plan.seeds.keys.first, "# refreshed by Mihomo\nproxies: []\n")
    before = snapshot
    id, = @router.apply
    assert_nil id
    assert_equal before, snapshot
    assert_equal 1, @store.backups.size
  end

  def test_removing_mapping_removes_only_owned_entries
    @router.add('github', 'dev')
    @router.apply
    @router.remove('github')
    @router.apply
    assert_equal ['DOMAIN-SUFFIX,existing.example,Default'], yaml('profiles/rules.yaml')['prepend']
    assert_equal ['User Group'], yaml('profiles/groups.yaml')['prepend'].map { |g| g['name'] }
    assert_empty yaml('profiles/merge.yaml')['proxy-providers']
    assert_equal 'off', yaml('profiles/merge.yaml')['find-process-mode']
  end

  def test_changing_subscription_replaces_owned_provider_and_group
    @router.add('github', 'dev')
    @router.apply
    old = @router.state['owned']['providers'].keys
    @router.add('github', 'backup')
    @router.apply
    providers = yaml('profiles/merge.yaml')['proxy-providers']
    assert_equal 1, providers.size
    assert_empty providers.keys & old
    assert_equal 'https://other.example.test/sub?token=fixture-other-token', providers.values.first['url']
    assert_equal 43, yaml('profiles/rules.yaml')['prepend'].size
  end

  def test_multiple_websites_share_one_provider_per_subscription
    @router.add('github', 'dev')
    @router.add('example.com', 'dev')
    @router.apply
    assert_equal 1, yaml('profiles/merge.yaml')['proxy-providers'].size
    assert_equal 44, yaml('profiles/rules.yaml')['prepend'].size
  end

  def test_specific_subdomain_precedes_parent_mapping
    @router.add('example.com', 'dev')
    @router.add('api.example.com', 'backup', true)
    @router.apply
    rules = yaml('profiles/rules.yaml')['prepend']
    assert rules[0].start_with?('DOMAIN,api.example.com,')
    assert rules[1].start_with?('DOMAIN-SUFFIX,example.com,')
    refute_equal rules[0].split(',').last, rules[1].split(',').last
  end

  def test_conflicting_preset_and_custom_domain_is_rejected
    @router.add('github', 'dev')
    @router.add('github.com', 'backup')
    error = assert_raises(VergeRouter::Error) { @router.plan }
    assert_includes error.message, '冲突'
  end

  def test_rollback_restores_original_bytes_and_keeps_mapping_intent
    originals = %w[merge groups rules].to_h { |n| [n, @store.read("profiles/#{n}.yaml")] }
    @router.add('github', 'dev')
    id, = @router.apply
    assert_equal id, @store.rollback
    originals.each { |n, bytes| assert_equal bytes, @store.read("profiles/#{n}.yaml") }
    assert_nil @store.read(VergeRouter::Router::STATE)
    assert_equal 1, @router.config['routes'].size
    assert_equal 'rolled_back', @store.manifest(id)['status']
  end

  def test_rollback_refuses_external_edit_without_partial_restore
    @router.add('github', 'dev')
    @router.apply
    @store.write('profiles/rules.yaml', @store.read('profiles/rules.yaml') + "# later user edit\n")
    before = snapshot
    assert_raises(VergeRouter::Error) { @store.rollback }
    assert_equal before, snapshot
  end

  def test_apply_preserves_unrelated_changes_made_after_previous_apply
    @router.add('github', 'dev')
    @router.apply
    document = VergeRouter::YamlDocument.new(@store.read('profiles/merge.yaml'))
    document.put('tcp-concurrent', true)
    @store.write('profiles/merge.yaml', document.dump)
    @router.add('example.com', 'dev')
    @router.apply
    assert_equal true, yaml('profiles/merge.yaml')['tcp-concurrent']
  end

  def test_apply_refuses_to_overwrite_manually_edited_managed_group
    @router.add('github', 'dev')
    @router.apply
    data = yaml('profiles/groups.yaml')
    data['prepend'].first['type'] = 'url-test'
    put_yaml('profiles/groups.yaml', data)
    before = snapshot
    assert_raises(VergeRouter::Error) { @router.apply }
    assert_equal before, snapshot
  end

  def test_transaction_recovers_all_files_after_mid_write_error
    @router.add('github', 'dev')
    originals = %w[merge groups rules].to_h { |n| [n, @store.read("profiles/#{n}.yaml")] }
    storage = @router.storage
    storage.singleton_class.alias_method :normal_write, :write
    storage.define_singleton_method(:write) do |path, bytes|
      if path == 'profiles/groups.yaml' && !@injected
        @injected = true
        raise IOError, 'injected failure'
      end
      normal_write(path, bytes)
    end
    assert_raises(VergeRouter::Error) { @router.apply }
    originals.each { |n, bytes| assert_equal bytes, @store.read("profiles/#{n}.yaml") }
    assert_nil @router.state
    assert_equal 'rolled_back', @store.manifest(@store.backups.first)['status']
  end

  def test_stale_plan_cannot_overwrite_a_later_edit
    @router.add('github', 'dev')
    plan = @router.plan
    @store.write('profiles/rules.yaml', @store.read('profiles/rules.yaml') + "# concurrent edit\n")
    before = snapshot
    assert_raises(VergeRouter::Error) { @store.transaction(plan.changes, plan.expected, plan.guards) }
    assert_equal before, snapshot
  end

  def test_prepared_transaction_can_be_recovered_after_process_exit
    @router.add('github', 'dev')
    id, = @router.apply
    m = @store.manifest(id)
    m['status'] = 'prepared'
    @store.write("verge-router/backups/#{id}/manifest.json", JSON.generate(m))
    entry = m['files'].first
    @store.write(entry['path'], @store.read("verge-router/backups/#{id}/#{entry['snapshot']}"))
    assert_raises(VergeRouter::Error) { @router.plan }
    @store.rollback(id)
    assert_nil @router.state
    assert_equal @merge, @store.read('profiles/merge.yaml')
  end

  def test_invalid_domains_cannot_inject_rules
    ['https://user:secret@example.com', '*.example.com', 'example.com,DIRECT', '127.0.0.1', 'bad..example', '-bad.example', "a.example\nMATCH,DIRECT"].each do |domain|
      assert_raises(VergeRouter::Error) { @router.add(domain, 'dev') }
    end
    assert_equal 'example.com', VergeRouter::Router.domain('EXAMPLE.COM.')
  end

  def test_duplicate_subscription_names_require_uid
    @catalog['items'].last['name'] = '开发订阅'
    put_yaml('profiles.yaml', @catalog)
    assert_raises(VergeRouter::Error) { @router.add('github', '开发订阅') }
    @router.add('github', 'dev')
    assert_equal 'dev', @router.config['routes'].first['subscription']
  end

  def test_changed_active_profile_is_rejected
    @router.add('github', 'dev')
    @catalog['current'] = 'dev'
    put_yaml('profiles.yaml', @catalog)
    assert_raises(VergeRouter::Error) { @router.plan }
  end

  def test_rejects_unsafe_profile_path
    @router.add('github', 'dev')
    @catalog['items'].find { |i| i['uid'] == 'merge' }['file'] = '../outside.yaml'
    put_yaml('profiles.yaml', @catalog)
    assert_raises(VergeRouter::Error) { @router.plan }
  end

  def test_symlinked_extension_is_not_followed
    @router.add('github', 'dev')
    File.unlink(@store.path('profiles/merge.yaml'))
    File.symlink(@store.path('profiles/dev.yaml'), File.join(@dir, 'profiles/merge.yaml'))
    assert_raises(VergeRouter::Error) { @router.plan }
  end

  def test_rejects_shared_extensions
    @router.add('github', 'dev')
    @catalog['items'].last['option'] = { 'merge' => 'merge' }
    put_yaml('profiles.yaml', @catalog)
    assert_raises(VergeRouter::Error) { @router.plan }
  end

  def test_include_all_providers_cannot_change_other_sites_silently
    @router.add('github', 'dev')
    runtime = yaml('clash-verge.yaml')
    runtime['proxy-groups'].first['include-all-providers'] = true
    put_yaml('clash-verge.yaml', runtime)
    assert_raises(VergeRouter::Error) { @router.plan }
  end

  def test_global_mode_is_rejected
    @router.add('github', 'dev')
    put_yaml('clash-verge.yaml', { 'mode' => 'global' })
    assert_raises(VergeRouter::Error) { @router.plan }
  end

  def test_node_source_without_proxies_is_rejected
    @router.add('github', 'dev')
    put_yaml('profiles/dev.yaml', { 'proxy-providers' => {} })
    assert_raises(VergeRouter::Error) { @router.plan }
  end

  def test_provider_name_collision_is_rejected
    @router.add('github', 'dev')
    token = Digest::SHA256.hexdigest('dev')[0, 12]
    put_yaml('profiles/merge.yaml', { 'proxy-providers' => { "VR_#{token}" => { 'type' => 'file', 'path' => 'user.yaml' } } })
    assert_raises(VergeRouter::Error) { @router.plan }
  end

  def test_rollback_manifest_cannot_target_unrelated_files
    @router.add('github', 'dev')
    id, = @router.apply
    m = @store.manifest(id)
    m['files'].first['path'] = 'profiles.yaml'
    @store.write("verge-router/backups/#{id}/manifest.json", JSON.generate(m))
    assert_raises(VergeRouter::Error) { @store.rollback(id) }
  end

  def test_cli_rejects_malformed_mapping_without_echoing_tokens
    @store.write(VergeRouter::Router::CONFIG, '{"url":"https://example.test?token=fixture-secret"')
    code, output, errors = cli('plan')
    assert_equal 1, code
    refute_includes output + errors, 'fixture-secret'
  end

  def test_cli_add_list_remove_and_help
    assert_equal 0, cli('add', 'example.com', '--to', 'dev').first
    assert_includes cli('list')[1], 'example.com → 开发订阅'
    assert_equal 0, cli('remove', 'example.com').first
    assert_includes cli('list')[1], '尚未添加'
    assert_equal 0, cli('--help').first
    assert_equal 1, cli('unknown').first
  end

  def fake_controller
    state = @router.state
    group = state['owned']['groups'].keys.first
    provider = state['owned']['providers'].keys.first
    node = "[VR:#{provider.sub('VR_', '')}] Fixture Node"
    responses = {
      '/configs' => { 'mode' => 'rule' },
      '/rules' => { 'rules' => state['owned']['rules'].map { |r| t, d, g = r.split(',', 3); { 'type' => t == 'DOMAIN' ? 'Domain' : 'DomainSuffix', 'payload' => d, 'proxy' => g } } },
      '/proxies' => { 'proxies' => { group => { 'all' => [node], 'now' => node } } },
      '/providers/proxies' => { 'providers' => { provider => { 'proxies' => [{ 'name' => node }] } } }
    }
    object = Object.new
    object.define_singleton_method(:get) { |path| responses.fetch(path) }
    [object, responses]
  end

  def test_verify_checks_rule_priority_and_selected_node_origin
    @router.add('github', 'dev')
    @router.apply
    controller, responses = fake_controller
    assert_equal 42, @router.verify(controller)['rule_count']
    responses['/rules']['rules'].unshift({ 'type' => 'Match', 'payload' => '', 'proxy' => 'DIRECT' })
    assert_raises(VergeRouter::Error) { @router.verify(controller) }
  end

  def test_verify_rejects_a_group_with_a_foreign_node
    @router.add('github', 'dev')
    @router.apply
    controller, responses = fake_controller
    responses['/proxies']['proxies'].values.first['all'] << 'DIRECT'
    assert_raises(VergeRouter::Error) { @router.verify(controller) }
  end

  def test_verify_requires_apply_after_mapping_change
    @router.add('github', 'dev')
    @router.apply
    @router.add('example.com', 'dev')
    assert_raises(VergeRouter::Error) { @router.verify(fake_controller.first) }
  end

  def test_controller_reads_unix_socket_and_handles_secret_without_logging
    socket_path = File.join(@dir, 'c.sock')
    server = UNIXServer.new(socket_path)
    request = nil
    thread = Thread.new do
      client = server.accept
      request = +''
      request << client.gets until request.end_with?("\r\n\r\n")
      body = JSON.generate('mode' => 'rule')
      client.write("HTTP/1.0 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
      client.close
    end
    put_yaml('clash-verge.yaml', { 'external-controller-unix' => socket_path, 'secret' => 'fixture-controller-secret' })
    assert_equal({ 'mode' => 'rule' }, VergeRouter::Controller.new(@store).get('/configs'))
    thread.join
    assert_includes request, 'Authorization: Bearer fixture-controller-secret'
  ensure
    server.close if server && !server.closed?
    thread.kill if thread && thread.alive?
  end

  def test_controller_refuses_remote_address
    put_yaml('clash-verge.yaml', { 'external-controller' => '192.0.2.1:9090', 'secret' => 'fixture-controller-secret' })
    assert_raises(VergeRouter::Error) { VergeRouter::Controller.new(@store).get('/configs') }
  end

  def test_generated_extensions_pass_real_mihomo_validation
    binary = ENV['MIHOMO_BIN']
    skip 'Set MIHOMO_BIN to run optional real-core validation' unless binary && File.executable?(binary)
    @router.add('github', 'dev')
    @router.apply
    runtime = yaml('clash-verge.yaml')
    runtime['find-process-mode'] = 'off'
    runtime['proxy-providers'] = yaml('profiles/merge.yaml')['proxy-providers']
    runtime['proxy-groups'] = yaml('profiles/groups.yaml')['prepend'] + runtime['proxy-groups']
    runtime['rules'] = yaml('profiles/rules.yaml')['prepend'] + runtime['rules']
    put_yaml('candidate.yaml', runtime)
    output, status = Open3.capture2e(binary, '-t', '-d', @dir, '-f', @store.path('candidate.yaml'))
    assert status.success?, output.gsub(%r{https?://[^\s"]+}, '[fixture URL]')
  end
end

class YamlDocumentTest < Minitest::Test
  def test_yaml_12_words_stay_strings
    data = VergeRouter::YamlDocument.new("a: off\nb: on\nc: yes\nd: no\ne: false\nf: true\ng: null\n").data
    assert_equal({ 'a' => 'off', 'b' => 'on', 'c' => 'yes', 'd' => 'no', 'e' => false, 'f' => true, 'g' => nil }, data)
  end

  def test_aliases_and_merge_keys
    doc = VergeRouter::YamlDocument.new("defaults: &d {mode: off, enabled: true}\nchild:\n  <<: *d\n  enabled: false\n")
    assert_equal({ 'mode' => 'off', 'enabled' => false }, doc.data['child'])
    doc.put('new', 42)
    assert_equal doc.data, VergeRouter::YamlDocument.new(doc.dump).data
  end

  def test_rejects_duplicate_keys_custom_tags_cycles_and_multiple_documents
    ["a: 1\na: 2", "a: !ruby/object:Object {}", "a: &a [*a]", "a: *unknown", "---\na: 1\n---\nb: 2"].each do |text|
      assert_raises(VergeRouter::Error) { VergeRouter::YamlDocument.new(text) }
    end
  end

  def test_comment_only_extension_is_supported
    document = VergeRouter::YamlDocument.new("# Empty extension\n")
    document.put('proxy-providers', {})
    assert_equal({ 'proxy-providers' => {} }, document.data)
  end
end
