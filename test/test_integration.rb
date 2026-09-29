# frozen_string_literal: true

require 'net/http'
require_relative 'test_manager'
require_relative 'test_router'
require_relative '../lib/verge_router/web_server'
require_relative '../lib/verge_router/menu'

class WebServerTest < Minitest::Test
  def setup
    @manager = Object.new
    @manager.define_singleton_method(:snapshot) { { 'version' => 'fixture', 'subscriptions' => [] } }
    @manager.define_singleton_method(:dispatch) { |action, args| { 'action' => action, 'args' => args } }
    @server = VergeRouter::WebServer.new(@manager)
    @thread = Thread.new { @server.serve }
  end

  def teardown
    @server.stop
    @thread.join(2)
    refute @thread.alive?, 'web server thread should terminate'
  end

  def request(path, body = nil, token: @server.token, host: nil, origin: nil)
    http = Net::HTTP.new('127.0.0.1', @server.port, nil)
    req = (body ? Net::HTTP::Post : Net::HTTP::Get).new(path)
    req['X-Verge-Token'] = token if token
    req['Host'] = host if host
    req['Origin'] = origin if origin
    if body
      req['Content-Type'] = 'application/json'
      req.body = JSON.generate(body)
    end
    http.request(req)
  end

  def test_assets_and_authenticated_snapshot
    page = request('/', token: nil)
    assert_equal '200', page.code
    assert_includes page.body.force_encoding('UTF-8'), '订阅总览'
    assert_includes page['Content-Security-Policy'], "frame-ancestors 'none'"
    refute_includes page.body, @server.token
    data = JSON.parse(request('/api/snapshot').body)
    assert_equal true, data['ok']
    assert_equal 'fixture', data['data']['version']
    assert_equal '200', request('/app.js', token: nil).code
    assert_equal '200', request('/style.css', token: nil).code
  end

  def test_api_requires_session_token_and_same_origin
    assert_equal '401', request('/api/snapshot', token: nil).code
    assert_equal '401', request('/api/snapshot', token: 'invalid').code
    assert_equal '403', request('/api/snapshot', host: 'other.example').code
    assert_equal '403', request('/api/snapshot', origin: 'https://other.example').code
    assert_equal '200', request('/api/snapshot', origin: "http://127.0.0.1:#{@server.port}").code
  end

  def test_post_dispatch_and_unknown_route
    response = request('/api/action', { 'action' => 'toggle', 'args' => { 'site' => 'example.com', 'enabled' => false } })
    assert_equal false, JSON.parse(response.body)['data']['args']['enabled']
    assert_equal '404', request('/missing').code
  end

  def test_error_responses_do_not_dump_credentials
    @manager.define_singleton_method(:snapshot) { raise VergeRouter::Error, 'bad https://fixture.example/secret' }
    response = request('/api/snapshot')
    assert_equal '422', response.code
    refute_includes response.body, 'fixture.example'
  end
end

class ManagerTest
  def test_native_bridge_script_compiles_without_executing
    skip 'AppleScript compiler is macOS-only' unless File.executable?('/usr/bin/osacompile')
    source = File.join(@dir, 'bridge.applescript')
    File.write(source, VergeRouter::ClientBridge::SCRIPT)
    output, status = Open3.capture2e('/usr/bin/osacompile', '-o', File.join(@dir, 'bridge.scpt'), source)
    assert status.success?, output
  end

  def test_scene_preview_never_changes_saved_mapping
    @manager.add('example.com', 'dev')
    @manager.save_scene('work')
    @manager.add('other.example', 'spare')
    before = file_bytes
    preview = @manager.preview_scene('work')
    assert_equal 1, preview['mapping']['routes'].size
    assert_equal before, file_bytes
  end

  def test_import_validates_everything_before_saving_and_rolls_back_together
    @manager.add('example.com', 'dev')
    document = @manager.export_document
    document['alerts']['remaining_percent'] = 200
    before = file_bytes
    assert_raises(VergeRouter::Error) { @manager.import_document(document, {}, true) }
    assert_equal before, file_bytes
    document['alerts']['remaining_percent'] = 9
    document['mapping']['routes'] = [{ 'domain' => 'other.example', 'subscription' => '备用订阅' }]
    @manager.import_document(document, {}, true)
    assert_equal 'other.example', @router.config['routes'].first['domain']
    @store.rollback
    assert_equal 'example.com', @router.config['routes'].first['domain']
    assert_equal 10, @manager.metadata['alerts']['remaining_percent']
  end

  def test_policy_for_unused_subscription_still_requires_matching_nodes
    assert_raises(VergeRouter::Error) { @manager.policy('spare', { 'mode' => 'fixed', 'node' => 'missing' }) }
  end

  def test_menu_eof_and_invalid_choice_are_recoverable
    input, output = StringIO.new("bogus\n0\n"), StringIO.new
    VergeRouter::Menu.new(@manager, input, output).run
    assert_includes output.string, '请选择列表中的编号'
    assert_nil @router.state
  end
end

class RouterTest
  def test_url_normalization_and_new_cli_commands
    assert_equal 0, cli('batch', 'https://EXAMPLE.com/path', 'api.example.org', '--to', 'dev').first
    assert_equal 2, @router.config['routes'].size
    assert_equal 0, cli('disable', 'example.com').first
    assert_equal false, @router.config['routes'].first['enabled']
    assert_equal 0, cli('scene', 'save', 'work').first
    assert_equal 0, cli('scene', 'list').first
    assert_equal 0, cli('status', '--json').first
  end

  def test_all_node_policy_modes_pass_real_core_validation
    binary = ENV['MIHOMO_BIN']
    skip 'Set MIHOMO_BIN for real-core validation' unless binary && File.executable?(binary)
    manager = VergeRouter::Manager.new(@router)
    manager.add('example.com', 'dev')
    %w[manual fixed auto fallback].each do |mode|
      policy = { 'mode' => mode, 'regions' => ['Fixture'] }
      policy['node'] = 'Fixture Node' if mode == 'fixed'
      manager.policy('dev', policy)
      @router.apply
      runtime = yaml('clash-verge.yaml')
      runtime['proxy-providers'] = yaml('profiles/merge.yaml')['proxy-providers']
      runtime['proxy-groups'] = yaml('profiles/groups.yaml')['prepend'] + runtime['proxy-groups']
      runtime['rules'] = yaml('profiles/rules.yaml')['prepend'] + runtime['rules']
      put_yaml('candidate.yaml', runtime)
      output, status = Open3.capture2e(binary, '-t', '-d', @dir, '-f', @store.path('candidate.yaml'))
      assert status.success?, "#{mode}: #{output}"
    end
  end
end
