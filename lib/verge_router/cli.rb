# frozen_string_literal: true

require 'optparse'
require_relative 'router'
require_relative 'controller'

module VergeRouter
  class CLI
    def self.run(argv, out: $stdout, err: $stderr)
      options = { directory: Router.default_directory, exact: false }
      parser = OptionParser.new do |o|
        o.banner = <<~TEXT
          用法：verge-router <命令> [参数] [选项]

          subscriptions                列出本机订阅名称和 UID
          presets                      列出内置网站预设
          add <网站或域名> --to <订阅>   保存网站映射，尚不修改代理配置
          remove <网站或域名>           删除映射，随后运行 apply
          list                         查看网站映射
          plan                         预览扩展变更，不写入任何文件
          apply                        备份并写入扩展；随后在应用中重新激活订阅
          verify                       只读检查内核运行规则与节点来源
          backups                      列出配置备份
          rollback [备份编号]           恢复上次写入前的配置

          选项：
        TEXT
        o.on('--data-dir DIR', 'Clash Verge 数据目录') { |v| options[:directory] = v }
        o.on('--config FILE', '使用指定 JSON 映射文件') { |v| options[:config] = v }
        o.on('--to SUBSCRIPTION', '目标订阅名称或 UID') { |v| options[:target] = v }
        o.on('--exact', '仅匹配完整域名，不包含子域名') { options[:exact] = true }
        o.on('-v', '--version', '版本') { out.puts('verge-router 0.1.0'); return 0 }
        o.on('-h', '--help', '帮助') { out.puts(o); return 0 }
      end
      parser.permute!(argv)
      command = argv.shift
      unless command
        out.puts(parser)
        return 0
      end
      if command == 'presets'
        raise Error, 'presets 不接受额外参数' unless argv.empty?
        Router.presets.each { |name, preset| out.puts("#{name}: #{preset['description']}") }
        return 0
      end
      router = Router.new(options[:directory], options[:config])
      case command
      when 'subscriptions'
        no_extra!(argv)
        router.subscriptions.each { |s| out.puts("#{s['active'] ? '*' : ' '} #{s['name']}\t#{s['uid']}\t#{s['type']}") }
      when 'add'
        raise Error, '用法：add <网站或域名> --to <订阅名称或 UID>' unless argv.size == 1 && options[:target]
        router.add(argv.first, options[:target], options[:exact])
        out.puts('映射已保存。运行 plan 预览，运行 apply 写入扩展。')
      when 'remove'
        raise Error, '用法：remove <网站或域名>' unless argv.size == 1
        router.remove(argv.first)
        out.puts('映射已删除。运行 apply 从扩展中移除工具管理的规则。')
      when 'list'
        no_extra!(argv)
        data = router.config
        out.puts("主订阅：#{router.resolve(data['base_profile'])['name']}")
        data['routes'].each do |r|
          out.puts("#{r['site'] || r['domain']}#{r['exact'] ? '（完整匹配）' : ''} → #{router.resolve(r['subscription'])['name']}")
        end
        out.puts('尚未添加网站。') if data['routes'].empty?
      when 'plan'
        no_extra!(argv)
        show_plan(router.plan, router.storage, out)
      when 'apply'
        no_extra!(argv)
        id, result = router.apply
        show_plan(result, router.storage, out, false)
        out.puts(id ? "已写入扩展，备份编号：#{id}" : '扩展已与映射一致，没有重复写入。')
        reload_hint(out)
      when 'verify'
        no_extra!(argv)
        result = router.verify
        out.puts("运行规则验证通过：#{result['rule_count']} 条。")
        result['groups'].each { |g| out.puts("#{g['group']} → #{g['node']}（#{g['node_count']} 个节点）") }
        out.puts('此检查验证规则和节点来源，不代表目标网站的实时连通性。')
      when 'backups'
        no_extra!(argv)
        ids = router.storage.backups
        ids.each { |id| out.puts("#{id}\t#{router.storage.manifest(id)['status']}") }
        out.puts('暂无备份。') if ids.empty?
      when 'rollback'
        raise Error, 'rollback 最多接受一个备份编号' if argv.size > 1
        id = router.storage.locked { router.storage.rollback(argv.first) }
        out.puts("已恢复备份：#{id}。网站映射文件保留，修改映射后再运行 apply。")
        reload_hint(out)
      else
        raise Error, '未知命令，请使用 --help'
      end
      0
    rescue Error, OptionParser::ParseError => e
      err.puts("错误：#{e.message.gsub(%r{https?://[^\s]+}, '[URL 已隐藏]')}")
      1
    rescue Interrupt
      err.puts('操作已中断。如有未完成写入，下次命令会提示对应回滚编号。')
      130
    rescue StandardError => e
      err.puts("无法完成操作（#{e.class}）。请检查文件权限和配置格式；未输出原始内容。")
      1
    end

    def self.no_extra!(args)
      raise Error, '该命令不接受位置参数' unless args.empty?
    end

    def self.show_plan(result, storage, out, files = true)
      out.puts("主订阅：#{result.base_name}")
      result.summary.each { |row| out.puts("#{row['site']} → #{row['subscription']}（#{row['rules']} 条域名规则）") }
      out.puts("工具管理的规则：#{result.state['owned']['rules'].size} 条")
      if files
        changed = result.changes.keys.select { |p| storage.read(p) != result.changes[p] }
        out.puts(changed.empty? ? '没有待写入变更。' : "待写入文件：\n#{changed.map { |p| "  #{p}" }.join("\n")}")
        out.puts("待创建本地节点缓存：#{result.seeds.size} 个")
      end
    end

    def self.reload_hint(out)
      out.puts('生效步骤：Clash Verge → 订阅 → 重新激活订阅，然后运行 verge-router verify。')
    end
  end
end
