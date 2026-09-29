# frozen_string_literal: true

require 'socket'
require 'net/http'
require 'timeout'

module VergeRouter
  # Access only the existing local controller; never enables a new API.
  class Controller
    def initialize(storage)
      raw = storage.read('clash-verge.yaml')
      raise Error, '没有运行配置，请先启动 Clash Verge 并激活订阅' unless raw
      @config = YamlDocument.new(raw, '运行配置').data
      @secret = @config.fetch('secret', '').to_s
      raise Error, '控制器密钥格式错误' if @secret.match?(/[\r\n]/)
    end

    def get(path)
      raise Error, '不支持的控制器接口' unless %w[/configs /rules /proxies /providers/proxies /connections].include?(path)
      request('GET', path)
    end

    def refresh_provider(name)
      request('PUT', '/providers/proxies/' + self.class.segment(name))
    end

    def select_node(group, node)
      request('PUT', '/proxies/' + self.class.segment(group), { 'name' => node })
    end

    def self.segment(value)
      URI.encode_www_form_component(value).gsub('+', '%20')
    end

    def request(method, path, payload = nil)
      unix = @config['external-controller-unix']
      status, body = if unix.is_a?(String) && !unix.empty?
                       unix_request(unix, method, path, payload)
                     else
                       tcp_request(method, path, payload)
                     end
      raise Error, "本地控制器返回 HTTP #{status}，请检查内核是否运行" unless (200..299).cover?(status)
      body.empty? ? {} : JSON.parse(body)
    rescue JSON::ParserError
      raise Error, '本地控制器返回了无效 JSON'
    rescue IOError, SystemCallError, Timeout::Error
      raise Error, '无法读取本地控制器，请确认 Clash Verge 正在运行'
    end

    def unix_request(socket_path, method, request_path, payload)
      socket = nil
      Timeout.timeout(10) do
        socket = UNIXSocket.new(socket_path)
        auth = @secret.empty? ? '' : "Authorization: Bearer #{@secret}\r\n"
        data = payload ? JSON.generate(payload) : ''
        socket.write("#{method} #{request_path} HTTP/1.0\r\nHost: localhost\r\n#{auth}Content-Type: application/json\r\nContent-Length: #{data.bytesize}\r\nConnection: close\r\n\r\n#{data}")
        raw = +''
        while (chunk = socket.read(16_384))
          raw << chunk
          raise Error, '本地控制器响应超过大小限制' if raw.bytesize > 16 * 1024 * 1024
        end
        header, body = raw.split("\r\n\r\n", 2)
        raise Error, '本地控制器响应格式错误' unless header && body && header.match?(/\AHTTP\/1\.[01] \d{3}/)
        raise Error, '本地控制器未遵循 HTTP/1.0 响应约定' if header.match?(/transfer-encoding:\s*chunked/i)
        [header.split(' ')[1].to_i, body]
      end
    ensure
      socket.close if socket && !socket.closed?
    end

    def tcp_request(method, path, payload)
      address = @config['external-controller']
      raise Error, '没有可用的本地控制器地址' unless address.is_a?(String) && !address.empty?
      begin
        uri = URI.parse("http://#{address}")
      rescue URI::InvalidURIError
        raise Error, '控制器地址格式错误'
      end
      unless %w[127.0.0.1 localhost ::1 [::1]].include?(uri.host) && !uri.userinfo && uri.path.empty? && !uri.query && !uri.fragment
        raise Error, 'verify 只允许本机回环控制器，拒绝向远程地址发送密钥'
      end
      http = Net::HTTP.new(uri.hostname, uri.port, nil) # Ignore HTTP_PROXY for local secrets.
      http.open_timeout = 3
      http.read_timeout = 10
      request = (method == 'GET' ? Net::HTTP::Get : Net::HTTP::Put).new(path)
      request['Authorization'] = "Bearer #{@secret}" unless @secret.empty?
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate(payload) if payload
      response = http.request(request)
      [response.code.to_i, response.body.to_s]
    end
  end

  class Router
    def verify(controller = nil)
      current = state
      raise Error, '尚未 apply 网站映射' unless current
      raise Error, '映射文件已改变，请先执行 plan 和 apply' unless current['mapping_hash'] == self.class.fingerprint(config)
      raise Error, '当前激活的主订阅与工具状态不同' unless catalog['current'] == current['base_uid']
      desired = plan
      if desired.changes.any? { |path, bytes| @storage.read(path) != bytes }
        raise Error, '订阅或节点偏好已改变，请重新 apply/deploy 后核验'
      end
      api = controller || Controller.new(@storage)
      raise Error, '内核当前不是规则模式，网站规则不会生效' unless api.get('/configs')['mode'] == 'rule'
      expected = current['owned']['rules'].map do |rule|
        type, domain, group = rule.split(',', 3)
        { 'type' => type == 'DOMAIN' ? 'Domain' : 'DomainSuffix', 'payload' => domain, 'proxy' => group }
      end
      actual = api.get('/rules').fetch('rules').take(expected.size).map do |rule|
        rule.select { |key, _| %w[type payload proxy].include?(key) }
      end
      raise Error, '运行中的规则尚未更新或被其他扩展覆盖，请重新激活订阅后重试' unless actual == expected
      proxies = api.get('/proxies').fetch('proxies')
      providers = api.get('/providers/proxies').fetch('providers')
      result = current['owned']['groups'].keys.map do |name|
        group = proxies[name]
        raise Error, '运行中的策略组尚未加载' unless group && group['all'].is_a?(Array) && !group['all'].empty?
        token = current['owned']['providers'].keys.find do |provider_name|
          prefix = "[VR:#{provider_name.sub(/\AVR_/, '')}] "
          group['all'].all? { |node| node.start_with?(prefix) }
        end
        provider = token && providers[token]
        members = provider && provider.fetch('proxies', []).map { |p| p['name'] }
        unless members && (group['all'] - members).empty? && group['all'].include?(group['now'])
          raise Error, '策略组含非目标订阅的节点或代理集合未就绪'
        end
        { 'group' => name, 'node' => group['now'], 'node_count' => group['all'].size }
      end
      { 'rule_count' => expected.size, 'groups' => result }
    end
  end
end
