# frozen_string_literal: true

require 'psych'
require 'json'

module VergeRouter
  class Error < StandardError; end

  # Edit the syntax tree instead of round-tripping through YAML 1.1 objects.
  # In particular, Mihomo's find-process-mode: off must remain a string.
  class YamlDocument
    M = Psych::Nodes::Mapping
    S = Psych::Nodes::Sequence
    V = Psych::Nodes::Scalar
    A = Psych::Nodes::Alias
    TAGS = (['!'] + %w[str int float bool null map seq merge].map { |x| "tag:yaml.org,2002:#{x}" }).freeze

    attr_reader :root

    def initialize(text, label = 'YAML')
      @label = label
      @stream = Psych.parse_stream(text)
      raise Error, "#{label}: 不支持多个 YAML 文档" if @stream.children.length > 1
      if @stream.children.empty? || @stream.children.first.root.nil?
        @stream = Psych.parse_stream("{}\n")
      end
      @root = @stream.children.first.root
      if @root.is_a?(V) && (@root.value.empty? || @root.value == 'null' || @root.value == '~')
        @stream = Psych.parse_stream("{}\n")
        @root = @stream.children.first.root
      end
      mapping(@root)
      self.class.decode(@root) # Reject duplicate keys, unsafe tags and cyclic aliases.
    rescue Psych::Exception
      # Parser exceptions can quote subscription URLs or credentials.
      raise Error, "#{label}: YAML 语法错误（已隐藏原始内容）"
    end

    def self.node(value)
      Psych.parse_stream(Psych.dump(value)).children.first.root
    end

    def self.decode(node, anchors = nil, visiting = [])
      if anchors.nil?
        anchors = {}
        walk = lambda do |n|
          raise Error, 'YAML 含不支持的类型标签' if n.respond_to?(:tag) && n.tag && !TAGS.include?(n.tag)
          anchors[n.anchor] = n if !n.is_a?(A) && n.respond_to?(:anchor) && n.anchor
          (n.children || []).each { |child| walk.call(child) } if n.respond_to?(:children)
        end
        walk.call(node)
      end
      raise Error, 'YAML 含循环别名' if visiting.include?(node.object_id)
      trail = visiting + [node.object_id]
      case node
      when A
        target = anchors[node.anchor]
        raise Error, 'YAML 含未定义别名' unless target
        decode(target, anchors, trail)
      when S
        node.children.map { |n| decode(n, anchors, trail) }
      when M
        result = {}
        explicit = {}
        node.children.each_slice(2) do |key_node, value_node|
          key = decode(key_node, anchors, trail)
          raise Error, 'YAML 映射键必须是字符串' unless key.is_a?(String)
          value = decode(value_node, anchors, trail)
          if key == '<<' && key_node.plain
            sources = value.is_a?(Array) ? value : [value]
            sources.reverse_each do |source|
              raise Error, 'YAML 合并键必须引用映射' unless source.is_a?(Hash)
              result.merge!(source)
            end
          else
            raise Error, 'YAML 含重复映射键' if explicit.key?(key)
            explicit[key] = value
          end
        end
        result.merge(explicit)
      when V
        value = node.value
        return value unless node.plain && !['!', 'tag:yaml.org,2002:str'].include?(node.tag)
        return true if value.match?(/\Atrue\z/i)
        return false if value.match?(/\Afalse\z/i)
        return nil if value.empty? || value == '~' || value.match?(/\Anull\z/i)
        return value.delete('_').to_i if value.match?(/\A[-+]?(?:0|[1-9][0-9_]*)\z/)
        return value.to_f if value.match?(/\A[-+]?[0-9]+\.[0-9]+(?:e[-+]?[0-9]+)?\z/i)
        value
      else
        raise Error, '不支持的 YAML 节点'
      end
    end

    def data
      self.class.decode(@root)
    end

    def dump
      @stream.to_yaml
    end

    def mapping(node)
      raise Error, "#{@label}: 待修改字段必须是直接定义的映射，不能是别名" unless node.is_a?(M)
      node
    end

    def sequence(node)
      raise Error, "#{@label}: 待修改字段必须是直接定义的列表，不能是别名" unless node.is_a?(S)
      node
    end

    def get(key, parent = @root)
      mapping(parent).children.each_slice(2) do |k, v|
        return v if k.is_a?(V) && k.value == key
      end
      nil
    end

    def put(key, value, parent = @root)
      put_node(key, self.class.node(value), parent)
    end

    def put_node(key, value, parent = @root)
      children = mapping(parent).children
      index = children.each_index.find { |i| i.even? && children[i].is_a?(V) && children[i].value == key }
      if index
        children[index + 1] = value
      else
        children.concat([self.class.node(key), value])
      end
      value
    end

    def delete(key, parent = @root)
      children = mapping(parent).children
      index = children.each_index.find { |i| i.even? && children[i].is_a?(V) && children[i].value == key }
      children.slice!(index, 2) if index
    end

    def ensure_map(key)
      mapping(get(key) || put(key, {}))
    end

    def ensure_sequence(key)
      sequence(get(key) || put(key, []))
    end
  end
end
