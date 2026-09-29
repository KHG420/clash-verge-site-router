# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'securerandom'
require 'time'

module VergeRouter
  class Storage
    attr_reader :root

    def initialize(root)
      raise Error, '找不到 Clash Verge 数据目录，请使用 --data-dir 指定' unless File.directory?(root)
      @root = File.realpath(root)
    end

    def path(relative)
      parts = relative.to_s.split('/', -1)
      if parts.empty? || parts.any? { |p| p.empty? || p == '..' || p == '.' || p.include?("\0") || p.include?('\\') }
        raise Error, '拒绝不安全的相对路径'
      end
      current = @root
      parts.each do |part|
        current = File.join(current, part)
        raise Error, '拒绝通过符号链接访问配置文件' if File.symlink?(current)
      end
      current
    end

    def read(relative)
      file = path(relative)
      File.file?(file) ? File.binread(file).force_encoding('UTF-8') : nil
    end

    def self.hash(bytes)
      bytes.nil? ? nil : Digest::SHA256.hexdigest(bytes)
    end

    def write(relative, bytes)
      file = path(relative)
      FileUtils.mkdir_p(File.dirname(file), mode: 0o700)
      temp = "#{file}.#{SecureRandom.hex(6)}.tmp"
      begin
        File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |io|
          io.write(bytes)
          io.flush
          io.fsync
        end
        path(relative) # Recheck symlinks immediately before replacement.
        File.rename(temp, file)
      ensure
        File.unlink(temp) if File.exist?(temp)
      end
    end

    def locked
      lock = path('verge-router/lock')
      FileUtils.mkdir_p(File.dirname(lock), mode: 0o700)
      File.open(lock, File::RDWR | File::CREAT, 0o600) do |file|
        raise Error, '另一个 verge-router 命令正在写入，请稍后重试' unless file.flock(File::LOCK_EX | File::LOCK_NB)
        yield
      ensure
        file.flock(File::LOCK_UN) if file
      end
    end

    def backups
      directory = path('verge-router/backups')
      return [] unless File.directory?(directory)
      Dir.children(directory).select do |id|
        id.match?(/\A\d{8}-\d{6}-[a-f0-9]{8}\z/) && File.file?(path("verge-router/backups/#{id}/manifest.json"))
      end.sort_by { |id| File.mtime(path("verge-router/backups/#{id}/manifest.json")) }.reverse
    end

    def manifest(id)
      raise Error, '无效的备份编号' unless id.to_s.match?(/\A\d{8}-\d{6}-[a-f0-9]{8}\z/)
      raw = read("verge-router/backups/#{id}/manifest.json")
      raise Error, '找不到备份清单' unless raw
      JSON.parse(raw)
    rescue JSON::ParserError
      raise Error, '备份清单损坏'
    end

    def check_pending!
      pending = backups.find { |id| manifest(id)['status'] == 'prepared' }
      raise Error, "检测到未完成的写入。请先执行 rollback #{pending}" if pending
    end

    def transaction(changes, expected, guards = {})
      check_pending!
      guards.merge(expected).each do |relative, digest|
        raise Error, '配置在预览后发生变化，请重新运行命令' unless self.class.hash(read(relative)) == digest
      end
      changes = changes.reject { |relative, bytes| read(relative) == bytes }
      return nil if changes.empty?
      id = "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(4)}"
      prefix = "verge-router/backups/#{id}"
      files = changes.keys.each_with_index.map do |relative, i|
        before = read(relative)
        snapshot = before.nil? ? nil : "#{i}.snapshot"
        write("#{prefix}/#{snapshot}", before) if snapshot
        { 'path' => relative, 'snapshot' => snapshot, 'before' => self.class.hash(before),
          'after' => self.class.hash(changes[relative]) }
      end
      m = { 'version' => 1, 'status' => 'prepared', 'created_at' => Time.now.iso8601, 'files' => files }
      write("#{prefix}/manifest.json", JSON.pretty_generate(m) + "\n")
      begin
        files.each do |entry|
          raise Error, '写入过程中检测到外部修改' unless self.class.hash(read(entry['path'])) == entry['before']
          write(entry['path'], changes.fetch(entry['path']))
        end
        m['status'] = 'committed'
        write("#{prefix}/manifest.json", JSON.pretty_generate(m) + "\n")
      rescue StandardError
        begin
          rollback(id)
        rescue StandardError
          raise Error, "写入中断，且存在外部修改。请检查备份并执行 rollback #{id}"
        end
        raise Error, '写入失败，已恢复修改前的配置'
      end
      id
    end

    def rollback(id = nil)
      id ||= backups.find { |candidate| %w[committed prepared].include?(manifest(candidate)['status']) }
      raise Error, '没有可回滚的备份' unless id
      m = manifest(id)
      raise Error, '备份版本或状态不支持' unless m['version'] == 1 && %w[committed prepared].include?(m['status'])
      entries = m.fetch('files')
      raise Error, '备份清单格式错误' unless entries.is_a?(Array) && entries.map { |x| x['path'] }.uniq.size == entries.size
      entries.each do |entry|
        relative = entry.fetch('path')
        unless relative.match?(%r{\Aprofiles/[A-Za-z0-9_.-]+\.yaml\z}) || %w[verge-router/state.json verge-router/routes.json verge-router/manager.json].include?(relative)
          raise Error, '备份含非工具管理的目标路径'
        end
        current = self.class.hash(read(relative))
        allowed = m['status'] == 'prepared' ? [entry['before'], entry['after']] : [entry['after']]
        raise Error, '配置在备份后已被修改，拒绝覆盖。请先检查差异' unless allowed.include?(current)
        if entry['snapshot']
          raise Error, '备份快照路径错误' unless entry['snapshot'].match?(/\A\d+\.snapshot\z/)
          raw = read("verge-router/backups/#{id}/#{entry['snapshot']}")
          raise Error, '备份校验失败' unless self.class.hash(raw) == entry['before']
        elsif entry['before']
          raise Error, '备份缺少原始文件'
        end
      end
      # An interrupted rollback remains recoverable with the same command.
      m['status'] = 'prepared'
      write("verge-router/backups/#{id}/manifest.json", JSON.pretty_generate(m) + "\n")
      entries.reverse_each do |entry|
        current = self.class.hash(read(entry['path']))
        next if current == entry['before']
        raise Error, '回滚过程中出现外部修改，已停止恢复' unless current == entry['after']
        if entry['snapshot']
          write(entry['path'], read("verge-router/backups/#{id}/#{entry['snapshot']}"))
        else
          File.unlink(path(entry['path'])) if File.exist?(path(entry['path']))
        end
      end
      m['status'] = 'rolled_back'
      write("verge-router/backups/#{id}/manifest.json", JSON.pretty_generate(m) + "\n")
      id
    end
  end
end
