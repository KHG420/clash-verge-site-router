# frozen_string_literal: true

module VergeRouter
  class Menu
    def initialize(manager, input, output)
      @manager, @input, @out = manager, input, output
    end

    def ask(label)
      @out.print("#{label}：")
      @out.flush
      value = @input.gets
      raise EOFError unless value
      value.strip
    end

    def choose_subscription
      list = @manager.router.subscriptions
      list.each_with_index { |item, i| @out.puts("#{i + 1}. #{item['name']}#{item['active'] ? '（主订阅）' : ''}") }
      choice = Integer(ask('选择订阅编号'), 10)
      raise Error, '编号不在列表中' unless (1..list.size).cover?(choice)
      list[choice - 1]['uid']
    end

    def show(value)
      @out.puts(JSON.pretty_generate(value))
    end

    def run
      loop do
        @out.puts("\n订阅管理\n1. 订阅总览\n2. 添加/批量配置网站\n3. 停用/恢复/删除映射\n4. 节点偏好\n5. 刷新订阅\n6. 诊断网站\n7. 预览并应用\n8. 场景\n9. 导入/导出\n10. 接管与回滚\n11. 提醒\n12. 别名与标签\n0. 退出")
        begin
          case ask('选择操作')
          when '0' then return
          when '1' then CLI.show_status(@manager.snapshot, @out)
          when '2'
            sites = ask('网站或网址，多个用空格分隔').split
            sub = choose_subscription
            show(@manager.add(sites, sub, ask('只匹配完整域名？输入 y，其余为包含子域名') == 'y'))
          when '3'
            show(@manager.routes)
            site = ask('网站')
            action = ask('输入 enable 恢复、disable 停用、remove 删除')
            case action
            when 'enable', 'disable' then show(@manager.toggle(site, action == 'enable'))
            when 'remove' then show(@manager.dispatch('remove', { 'site' => site }))
            else raise Error, '未知操作'
            end
          when '4'
            sub = choose_subscription
            show(@manager.nodes(sub))
            mode = ask('模式 manual/fixed/auto/fallback')
            values = { 'mode' => mode, 'regions' => ask('地区关键词，逗号分隔；留空不限').split(',').map(&:strip).reject(&:empty?) }
            values['node'] = ask('节点原始名称') if mode == 'fixed'
            show(@manager.policy(sub, values))
          when '5'
            sub = ask('全部刷新输入 all，单个刷新按回车') == 'all' ? 'all' : choose_subscription
            show(@manager.refresh(sub))
          when '6' then show(@manager.diagnose(ask('域名或网址')))
          when '7'
            show(@manager.plan)
            show(@manager.deploy) if ask('写入并尝试重新激活？输入 y') == 'y'
          when '8'
            show(@manager.metadata['scenarios'].keys)
            action, name = ask('save/use/delete'), ask('场景名')
            show(@manager.dispatch("scene-#{action}", { 'name' => name, 'apply' => false }))
          when '9'
            action, path = ask('export/import'), ask('文件路径')
            if action == 'export'
              File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(JSON.pretty_generate(@manager.export_document) + "\n") }
              @out.puts('已导出。')
            elsif action == 'import'
              raise Error, '文件超过 1 MiB' if File.size(path) > 1024 * 1024
              document = JSON.parse(File.read(path))
              preview = @manager.import_document(document)
              show(preview)
              bindings = preview['missing'].to_h { |name| @out.puts("绑定 #{name}"); [name, choose_subscription] }
              show(@manager.import_document(document, bindings, true)) if ask('保存导入？输入 y') == 'y'
            end
          when '10'
            action = ask('adopt 接管 / rollback 回滚')
            if action == 'adopt'
              show(@manager.adoptions)
              id = ask('接管编号')
              show(@manager.adopt(id))
              show(@manager.adopt(id, true)) if ask('确认接管？输入 y') == 'y'
            elsif action == 'rollback'
              show(@manager.router.storage.backups)
              id = ask('备份编号，留空使用最近一次')
              show(@manager.dispatch('rollback', { 'id' => id.empty? ? nil : id })) if ask('恢复备份会变更配置，输入 y 确认') == 'y'
            end
          when '11'
            show(@manager.alerts)
            action = ask('配置提醒输入 settings，发送系统通知输入 notify，其余返回')
            if action == 'settings'
              show(@manager.configure_alerts({ 'expiry_days' => Integer(ask('到期前天数')), 'remaining_percent' => Integer(ask('剩余流量百分比')), 'stale_days' => Integer(ask('超过多少天未更新')) }))
            elsif action == 'notify'
              show(@manager.notify_alerts)
            end
          when '12'
            sub = choose_subscription
            show(@manager.alias_subscription(sub, ask('本地别名'), ask('标签，逗号分隔').split(',').map(&:strip).reject(&:empty?)))
          else @out.puts('请选择列表中的编号。')
          end
        rescue Error, ArgumentError, JSON::ParserError, SystemCallError => e
          @out.puts(e.is_a?(Error) ? "操作未完成：#{e.message}" : '输入或文件无效，请重试。')
        end
      end
    rescue EOFError
      @out.puts("\n已退出菜单。")
    end
  end
end
