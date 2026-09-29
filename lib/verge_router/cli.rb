# frozen_string_literal: true

require 'optparse'
require_relative 'router'
require_relative 'controller'
require_relative 'actions'

module VergeRouter
  class CLI
    def self.run(argv, out: $stdout, err: $stderr, input: $stdin)
      options = { directory: Router.default_directory, exact: false, bindings: {}, regions: [], tags: [], port: 0, interval: 900 }
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

          menu / 无参数                交互式管理（无参数仅在终端内进入菜单）
          web                          启动本地网页面板，Ctrl+C 停止
          status                       订阅总览与生效状态
          batch <网站...> --to <订阅>    批量保存映射，支持完整网址
          enable/disable <网站>         恢复或暂停映射
          alias <订阅> <别名>           设置本地别名，可附 --tags
          nodes <订阅>                  查看节点与当前偏好
          policy <订阅> --mode <模式>   manual/fixed/auto/fallback
          diagnose <域名或网址>         分流预期、运行候选规则和实际连接
          deploy                       写入、客户端重新激活、核验
          refresh [订阅或 all]          通过客户端刷新并核对结果
          scene list/save/use/delete [名称]  管理场景，use 可附 --apply
          export [文件]                 导出不含凭证的映射与场景
          import <文件>                 预览导入，--commit 后保存
          adopt [条目编号]              预览手工配置接管，--commit 后执行
          alerts / watch                查看提醒 / 持续检查提醒

          选项：
        TEXT
        o.on('--data-dir DIR', 'Clash Verge 数据目录') { |v| options[:directory] = v }
        o.on('--config FILE', '使用指定 JSON 映射文件') { |v| options[:config] = v }
        o.on('--to SUBSCRIPTION', '目标订阅名称或 UID') { |v| options[:target] = v }
        o.on('--exact', '仅匹配完整域名，不包含子域名') { options[:exact] = true }
        o.on('--json', '以 JSON 输出管理信息') { options[:json] = true }
        o.on('--mode MODE', '节点选择模式') { |v| options[:mode] = v }
        o.on('--node NAME', '固定节点的原始名称') { |v| options[:node] = v }
        o.on('--regions LIST', '节点名称筛选词，用逗号分隔') { |v| options[:regions] = v.split(',').map(&:strip).reject(&:empty?) }
        o.on('--tags LIST', '订阅标签，用逗号分隔') { |v| options[:tags] = v.split(',').map(&:strip).reject(&:empty?) }
        o.on('--bind NAME=UID', '导入时绑定订阅，可重复') { |v| key, val = v.split('=', 2); raise Error, '绑定需要 NAME=UID' unless val; options[:bindings][key] = val }
        o.on('--commit', '确认执行导入或接管') { options[:commit] = true }
        o.on('--apply', '切换场景后立即应用与核验') { options[:apply] = true }
        o.on('--notify', '发送新出现的系统提醒') { options[:notify] = true }
        o.on('--interval SECONDS', Integer, 'watch 间隔，至少 60 秒，默认 900') { |v| options[:interval] = v }
        o.on('--port PORT', Integer, '网页端口，默认自动分配') { |v| options[:port] = v }
        o.on('--open', '启动面板时在默认浏览器打开') { options[:open] = true }
        o.on('-v', '--version', '版本') { out.puts('verge-router 0.2.0'); return 0 }
        o.on('-h', '--help', '帮助') { out.puts(o); return 0 }
      end
      parser.permute!(argv)
      command = argv.shift
      unless command
        if input.respond_to?(:tty?) && input.tty?
          command = 'menu'
        else
          out.puts(parser)
          return 0
        end
      end
      if command == 'presets'
        raise Error, 'presets 不接受额外参数' unless argv.empty?
        Router.presets.each { |name, preset| out.puts("#{name}: #{preset['description']}") }
        return 0
      end
      router = Router.new(options[:directory], options[:config])
      manager = Manager.new(router)
      case command
      when 'menu'
        require_relative 'menu'
        Menu.new(manager, input, out).run
      when 'web'
        no_extra!(argv)
        require_relative 'web_server'
        server = WebServer.new(manager, port: options[:port])
        out.puts("本地面板：#{server.url}\n仅监听本机。Ctrl+C 停止服务，关闭网页不会自动停止。")
        out.flush
        if options[:open]
          if RUBY_PLATFORM.include?('darwin')
            system('open', '-g', server.url)
          elsif RUBY_PLATFORM.include?('linux')
            system('xdg-open', server.url, out: File::NULL, err: File::NULL)
          end
        end
        begin
          server.serve
        ensure
          server.stop
        end
      when 'status'
        no_extra!(argv)
        snapshot = manager.snapshot
        options[:json] ? output(snapshot, out) : show_status(snapshot, out)
      when 'batch'
        raise Error, '需要网站列表和 --to' if argv.empty? || !options[:target]
        output(manager.add(argv, options[:target], options[:exact]), out)
      when 'enable', 'disable'
        raise Error, '需要一个网站' unless argv.size == 1
        output(manager.toggle(argv.first, command == 'enable'), out)
      when 'alias'
        raise Error, '用法：alias <订阅> <别名>' unless argv.size == 2
        output(manager.alias_subscription(argv[0], argv[1], options[:tags]), out)
      when 'nodes', 'policy', 'diagnose'
        raise Error, '需要一个订阅或域名参数' unless argv.size == 1
        result = case command
                 when 'nodes' then manager.nodes(argv.first)
                 when 'diagnose' then manager.diagnose(argv.first)
                 else
                   raise Error, '请指定 --mode' unless options[:mode]
                   manager.policy(argv.first, { 'mode' => options[:mode], 'node' => options[:node], 'regions' => options[:regions] }.reject { |_, value| value.nil? })
                 end
        output(result, out)
      when 'deploy'
        no_extra!(argv)
        output(manager.deploy, out)
      when 'refresh'
        raise Error, 'refresh 最多一个订阅参数' if argv.size > 1
        output(manager.refresh(argv.first || 'all'), out)
      when 'scene'
        action, name = argv
        raise Error, 'scene 参数过多' if argv.size > 2
        result = case action
                 when 'list' then manager.metadata['scenarios'].map { |n, map| { 'name' => n, 'route_count' => map['routes'].size } }
                 when 'save' then manager.save_scene(name)
                 when 'use' then manager.use_scene(name, options[:apply])
                 when 'delete' then manager.delete_scene(name)
                 else raise Error, 'scene 支持 list/save/use/delete'
                 end
        output(result, out)
      when 'export'
        raise Error, 'export 最多一个文件名' if argv.size > 1
        result = manager.export_document
        if argv.first
          File.open(argv.first, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.pretty_generate(result) + "\n") }
          out.puts('无凭证配置已导出。')
        else
          output(result, out)
        end
      when 'import'
        raise Error, '需要一个导出文件' unless argv.size == 1
        raise Error, '导入文件超过 1 MiB' if File.size(argv.first) > 1024 * 1024
        document = JSON.parse(File.read(argv.first))
        output(manager.import_document(document, options[:bindings], options[:commit]), out)
      when 'adopt'
        raise Error, 'adopt 最多一个条目编号' if argv.size > 1
        output(argv.empty? ? manager.adoptions : manager.adopt(argv.first, options[:commit]), out)
      when 'alerts'
        no_extra!(argv)
        output(options[:notify] ? manager.notify_alerts : manager.alerts, out)
      when 'watch'
        no_extra!(argv)
        raise Error, 'watch 间隔至少 60 秒' if options[:interval] < 60
        out.puts('提醒检查已启动；仅在新问题出现时通知。Ctrl+C 停止。')
        loop do
          result = manager.notify_alerts
          output(result, out) if result['sent'] > 0
          sleep options[:interval]
        end
      when 'subscriptions'
        no_extra!(argv)
        router.subscriptions.each { |s| out.puts("#{s['active'] ? '*' : ' '} #{s['name']}\t#{s['uid']}\t#{s['type']}") }
      when 'add'
        raise Error, '用法：add <网站或域名> --to <订阅名称或 UID>' unless argv.size == 1 && options[:target]
        manager.add([argv.first], options[:target], options[:exact])
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
          out.puts("#{r['site'] || r['domain']}#{r['exact'] ? '（完整匹配）' : ''} → #{router.resolve(r['subscription'])['name']}#{r['enabled'] == false ? '（已停用）' : ''}")
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

    def self.output(value, out)
      out.puts(JSON.pretty_generate(value))
    end

    def self.show_status(snapshot, out)
      out.puts("主订阅：#{snapshot['base']['name']} · #{snapshot['status']['label']}\n#{snapshot['status']['message']}\n")
      snapshot['subscriptions'].each do |sub|
        remaining = sub['remaining'] ? format('%.2f GiB', sub['remaining'] / 1_073_741_824.0) : '未知'
        expiry = sub['expires_at'] ? Time.at(sub['expires_at']).strftime('%Y-%m-%d') : '未知'
        out.puts("#{sub['alias'].to_s.empty? ? sub['name'] : sub['alias']} [#{sub['role']}] #{sub['node_count']} 节点 | 剩余 #{remaining} | 到期 #{expiry}")
        out.puts("  网站：#{sub['sites'].join('、')}") unless sub['sites'].empty?
      end
      snapshot['alerts'].each { |alert| out.puts("提醒 · #{alert['subscription']}：#{alert['message']}") }
      out.puts("待接管手工配置：#{snapshot['adoptions'].size} 组；场景：#{snapshot['scenarios'].size} 个。")
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
