# frozen_string_literal: true

require 'open3'

module VergeRouter
  # Verge exposes subscription commands only inside Tauri. Use the client's own
  # accessible buttons; never write its in-memory subscription registry behind it.
  class ClientBridge
    def initialize(directory)
      @directory = directory
    end
    SCRIPT = <<~'APPLESCRIPT'
      on textMatches(el, wanted)
        tell application "System Events"
          repeat with attributeName in {"AXTitle", "AXDescription", "AXHelp", "AXValue"}
            try
              if (value of attribute attributeName of el as text) is wanted then return true
            end try
          end repeat
        end tell
        return false
      end textMatches
      on run argv
        with timeout of 8 seconds
        set actionName to item 1 of argv
        set profileName to item 2 of argv
        tell application "System Events"
          if not (exists process "Clash Verge") then return "not_running"
          tell process "Clash Verge"
            if (count of windows) is 0 then return "open_profiles"
            set elementsList to entire contents of window 1
          end tell
        end tell
        set candidates to {}
        repeat with el in elementsList
          if my textMatches(el, actionName) then
            if profileName is "" then
              set end of candidates to contents of el
            else
              tell application "System Events"
                try
                  set p to value of attribute "AXParent" of el
                  repeat 3 times
                    set foundProfile to false
                    repeat with sibling in (entire contents of p)
                      if my textMatches(sibling, profileName) then set foundProfile to true
                    end repeat
                    if foundProfile then
                      set end of candidates to contents of el
                      exit repeat
                    end if
                    set p to value of attribute "AXParent" of p
                  end repeat
                end try
              end tell
            end if
          end if
        end repeat
        if (count of candidates) is not 1 then return "open_profiles"
        tell application "System Events"
          perform action "AXPress" of item 1 of candidates
        end tell
        return "triggered"
        end timeout
      end run
    APPLESCRIPT

    def status
      default = Router.default_directory
      available = RUBY_PLATFORM.include?('darwin') && File.directory?(default) && File.realpath(default) == @directory && File.executable?('/usr/bin/osascript')
      { 'available' => available, 'message' => available ? '自动操作需打开 Clash Verge 的订阅页面，并允许终端的辅助功能权限。' : '此系统或自定义数据目录请在 Clash Verge 手动刷新或重新激活，然后核验。' }
    end

    def perform(action, profile_name = '')
      return { 'triggered' => false, 'message' => status['message'] } unless status['available']
      label = { 'reactivate' => '重新激活订阅', 'refresh_all' => '更新所有订阅', 'refresh' => '刷新' }.fetch(action)
      output, _error, result = Open3.capture3('/usr/bin/osascript', '-e', SCRIPT, label, profile_name)
      triggered = result.success? && output.strip == 'triggered'
      { 'triggered' => triggered, 'message' => triggered ? '已触发客户端操作，正在核对实际结果。' : status['message'] }
    rescue SystemCallError
      { 'triggered' => false, 'message' => '无法操作客户端，请手动完成后重新核验。' }
    end
  end
end
