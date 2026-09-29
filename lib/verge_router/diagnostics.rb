# frozen_string_literal: true

module VergeRouter
  class Manager
    def diagnose(value)
      domain = Router.site_key(value)
      domain = 'github.com' if domain == 'github'
      rules = @router.plan.state['owned']['rules']
      planned = rules.find do |rule|
        type, payload, = rule.split(',', 3)
        type == 'DOMAIN' ? payload == domain : domain == payload || domain.end_with?(".#{payload}")
      end
      plan_row = if planned
                   group = planned.split(',', 3)[2]
                   { 'group' => group, 'subscription' => group.sub(/\A网站分流 · /, '').sub(/ · [a-f0-9]{6}\z/, ''), 'enabled' => true }
                 end
      warnings, observed = [], []
      runtime_row = nil
      begin
        uncertain = false
        api.get('/rules').fetch('rules').each do |rule|
          type, payload = rule['type'], rule['payload'].to_s.downcase
          match = case type
                  when 'Domain' then domain == payload
                  when 'DomainSuffix' then domain == payload || domain.end_with?(".#{payload}")
                  when 'DomainKeyword' then domain.include?(payload)
                  when 'Match' then true
                  else
                    uncertain = true # IP, process, logical and rule-set evaluation needs more context.
                    false
                  end
          next unless match
          runtime_row = { 'rule' => "#{type},#{rule['payload']}", 'group' => rule['proxy'], 'certain' => !uncertain,
                          'message' => uncertain ? '前面存在需 IP、进程或规则集上下文的规则；这是候选匹配，以实际连接为准。' : '按当前运行规则的域名条件匹配。' }
          break
        end
        observed = api.get('/connections').fetch('connections', []).select { |conn| conn.fetch('metadata', {})['host'].to_s.downcase == domain }.map do |conn|
          chain = Array(conn['chains'])
          { 'rule' => [conn['rule'], conn['rulePayload']].compact.join(','), 'chain' => chain, 'node' => chain.first }
        end.uniq.take(20)
        warnings << '当前没有该域名的活动连接；打开网站后重试，不代表网站不可达。' if observed.empty?
      rescue Error, KeyError => e
        warnings << (e.is_a?(Error) ? e.message : '控制器未提供完整规则或连接信息')
      end
      { 'domain' => domain, 'planned' => plan_row, 'runtime' => runtime_row, 'observed' => observed, 'warnings' => warnings }
    end

    def notify_alerts(notifier = nil)
      list = alerts
      current_ids = list.map { |row| row['id'] + ':' + row['level'] }
      previous = metadata.fetch('notified', [])
      fresh = list.reject { |row| previous.include?(row['id'] + ':' + row['level']) }
      notifier ||= lambda do |text|
        raise Error, '系统通知仅支持 macOS；其他系统可查看 alerts 输出或网页提醒。' unless RUBY_PLATFORM.include?('darwin')
        script = 'on run argv' + "\n" + 'display notification (item 1 of argv) with title "订阅管理"' + "\nend run"
        _, _, status = Open3.capture3('/usr/bin/osascript', '-e', script, text)
        raise Error, '无法发送系统通知，请查看系统通知设置。' unless status.success?
      end
      unless fresh.empty?
        notifier.call(fresh.map { |row| "#{row['subscription']}：#{row['message']}" }.join("\n"))
      end
      edit_metadata { |meta| meta['notified'] = current_ids } if previous != current_ids
      { 'message' => fresh.empty? ? '没有新的提醒。' : '已发送新的订阅提醒。', 'sent' => fresh.size, 'alerts' => list }
    end
  end
end
