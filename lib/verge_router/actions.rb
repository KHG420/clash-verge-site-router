# frozen_string_literal: true

require_relative 'manager'

module VergeRouter
  class Manager
    def dispatch(action, args = {})
      raise Error, '操作参数需要对象' unless args.is_a?(Hash)
      case action
      when 'add' then add(args.fetch('site'), args.fetch('subscription'), args['exact'] == true)
      when 'batch' then add(args.fetch('sites'), args.fetch('subscription'), args['exact'] == true)
      when 'remove'
        @router.remove(args.fetch('site'))
        { 'message' => '映射已删除，应用后生效。' }
      when 'toggle' then toggle(args.fetch('site'), args.fetch('enabled'))
      when 'alias' then alias_subscription(args.fetch('subscription'), args.fetch('alias'), args.fetch('tags', []))
      when 'policy' then policy(args.fetch('subscription'), args)
      when 'refresh' then refresh(args.fetch('subscription', 'all'))
      when 'deploy' then deploy
      when 'verify'
        { 'state' => 'verified', 'message' => '运行规则和节点来源核验通过。', 'verification' => @router.verify(api) }
      when 'scene-save' then save_scene(args.fetch('name'))
      when 'scene-use' then use_scene(args.fetch('name'), args['apply'] == true)
      when 'scene-delete' then delete_scene(args.fetch('name'))
      when 'import' then import_document(args.fetch('document'), args.fetch('bindings', {}), args['commit'] == true)
      when 'adopt' then adopt(args.fetch('id'), args['commit'] == true)
      when 'rollback'
        id = @router.storage.locked { @router.storage.rollback(args['id']) }
        triggered = @bridge.perform('reactivate')
        { 'state' => 'awaiting_client', 'backup' => id, 'message' => "已恢复备份。#{triggered['message']} 请核对运行状态；映射可能仍有待应用改动。" }
      when 'alerts-config' then configure_alerts(args)
      when 'notify' then notify_alerts
      else raise Error, '未知操作'
      end
    rescue KeyError
      raise Error, '缺少该操作的必要参数'
    end
  end
end
