# frozen_string_literal: true

require_relative 'actions'
require 'socket'
require 'timeout'

module VergeRouter
  class WebServer
    LIMIT = 1024 * 1024
    attr_reader :port, :token

    def initialize(manager, port: 0)
      @manager, @token = manager, SecureRandom.hex(32)
      @listener = TCPServer.new('127.0.0.1', port)
      @port = @listener.addr[1]
      @mutex, @clients, @threads = Mutex.new, [], []
      @closed = false
      @assets = File.expand_path('../../web', __dir__)
    end

    def url
      "http://127.0.0.1:#{@port}/#token=#{@token}"
    end

    def serve
      until @closed
        socket = @listener.accept
        @clients << socket
        @threads.reject! { |thread| !thread.alive? }
        if @threads.size >= 12
          respond(socket, 503, { 'ok' => false, 'error' => '请求过多，请稍后重试。' })
          socket.close
          next
        end
        @threads << Thread.new(socket) do |client|
          begin
            handle(client)
          rescue IOError, SystemCallError
            # Closing the window or stopping the server is not an application failure.
          ensure
            client.close unless client.closed?
            @clients.delete(client)
          end
        end
      end
    rescue IOError, Errno::EBADF
      raise unless @closed
    ensure
      stop
      @threads.each { |thread| thread.join(1) }
    end

    def stop
      @closed = true
      @listener.close unless @listener.closed?
      @clients.dup.each { |socket| socket.close unless socket.closed? }
    end

    def handle(socket)
      method, target, headers, body = read_request(socket)
      return respond(socket, 403, { 'ok' => false, 'error' => '只允许本机页面访问。' }) unless headers['host'] == "127.0.0.1:#{@port}"
      origin = headers['origin']
      return respond(socket, 403, { 'ok' => false, 'error' => '拒绝跨站请求。' }) if origin && origin != "http://127.0.0.1:#{@port}"
      path, query = target.split('?', 2)
      assets = { '/' => ['index.html', 'text/html; charset=utf-8'], '/app.js' => ['app.js', 'text/javascript; charset=utf-8'], '/style.css' => ['style.css', 'text/css; charset=utf-8'] }
      if method == 'GET' && assets.key?(path)
        name, type = assets.fetch(path)
        return respond(socket, 200, File.binread(File.join(@assets, name)), type)
      end
      return respond(socket, 401, { 'ok' => false, 'error' => '页面会话已失效，请使用终端中完整的访问链接。' }) unless token_valid?(headers['x-verge-token'])
      args = URI.decode_www_form(query.to_s).to_h
      result = @mutex.synchronize do
        case [method, path]
        when ['GET', '/api/snapshot'] then @manager.snapshot
        when ['GET', '/api/plan'] then @manager.plan
        when ['GET', '/api/diagnose'] then @manager.diagnose(args.fetch('domain'))
        when ['GET', '/api/nodes'] then @manager.nodes(args.fetch('subscription'))
        when ['GET', '/api/export'] then @manager.export_document
        when ['GET', '/api/scene'] then @manager.preview_scene(args.fetch('name'))
        when ['POST', '/api/action']
          raise Error, '操作请求必须使用 JSON' unless headers['content-type'].to_s.split(';').first == 'application/json'
          data = JSON.parse(body)
          raise Error, '操作请求格式错误' unless data.is_a?(Hash)
          @manager.dispatch(data.fetch('action'), data.fetch('args', {}))
        else
          return respond(socket, 404, { 'ok' => false, 'error' => '没有这个接口。' })
        end
      end
      respond(socket, 200, { 'ok' => true, 'data' => result })
    rescue Error => e
      respond(socket, 422, { 'ok' => false, 'error' => e.message.gsub(%r{https?://[^\s]+}, '[URL 已隐藏]') })
    rescue JSON::ParserError, KeyError, ArgumentError
      respond(socket, 400, { 'ok' => false, 'error' => '请求格式错误，请检查输入。' })
    rescue Timeout::Error
      respond(socket, 408, { 'ok' => false, 'error' => '读取请求超时。' })
    rescue StandardError => e
      respond(socket, 500, { 'ok' => false, 'error' => "操作未完成（#{e.class}），请检查配置和权限。" })
    end

    def token_valid?(input)
      return false unless input.is_a?(String) && input.bytesize == @token.bytesize
      input.bytes.zip(@token.bytes).inject(0) { |value, (a, b)| value | (a ^ b) }.zero?
    end

    def read_request(socket)
      Timeout.timeout(5) do
        line = socket.gets("\n", 8193)
        raise Error, '无效 HTTP 请求' unless line && line.bytesize <= 8192
        method, target, version = line.strip.split(' ')
        raise Error, '无效 HTTP 请求' unless %w[GET POST].include?(method) && target && target.start_with?('/') && %w[HTTP/1.0 HTTP/1.1].include?(version)
        headers, size = {}, 0
        loop do
          line = socket.gets("\n", 8193)
          raise Error, '无效 HTTP 请求头' unless line
          size += line.bytesize
          raise Error, '请求头超过限制' if size > 32_768
          break if line == "\r\n"
          key, value = line.strip.split(':', 2)
          raise Error, '无效 HTTP 请求头' unless value && key.match?(/\A[a-zA-Z0-9-]+\z/) && !headers.key?(key.downcase)
          headers[key.downcase] = value.strip
        end
        raise Error, '不支持分块请求' if headers['transfer-encoding']
        length = Integer(headers.fetch('content-length', '0'), 10)
        raise Error, '请求正文超过限制' unless (0..LIMIT).cover?(length)
        body = length.zero? ? '' : socket.read(length)
        raise Error, '请求正文不完整' unless body && body.bytesize == length
        [method, target, headers, body]
      end
    end

    def respond(socket, code, value, type = 'application/json; charset=utf-8')
      body = value.is_a?(String) ? value : JSON.generate(value)
      reason = { 200 => 'OK', 400 => 'Bad Request', 401 => 'Unauthorized', 403 => 'Forbidden', 404 => 'Not Found', 408 => 'Request Timeout', 422 => 'Unprocessable Entity', 500 => 'Internal Server Error', 503 => 'Service Unavailable' }.fetch(code)
      policy = "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
      socket.write("HTTP/1.1 #{code} #{reason}\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: #{policy}\r\nConnection: close\r\n\r\n#{body}")
    end
  end
end
