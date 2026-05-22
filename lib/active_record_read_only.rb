# frozen_string_literal: true

require "set"
require_relative "active_record_read_only/version"

module ActiveRecordReadOnly
  class Error < StandardError; end

  module Registry
    @allowed = {}
    @mutex = Mutex.new

    class << self
      def allow(klass, path)
        @mutex.synchronize { (@allowed[klass] ||= Set.new) << path }
      end

      def caller_allowed?(klass, locations)
        current = klass
        while current
          paths = @allowed[current]
          if paths && locations.any? { |loc| paths.include?(loc.path) }
            return true
          end
          current = current.respond_to?(:superclass) ? current.superclass : nil
        end
        false
      end

      def clear
        @mutex.synchronize { @allowed.clear }
      end

      def paths_for(klass)
        (@allowed[klass] || Set.new).dup
      end
    end
  end

  module Behavior
    def readonly?
      return false if ActiveRecordReadOnly::Registry.caller_allowed?(self.class, caller_locations)
      true
    end
  end

  module Setup
    def self.included(klass)
      klass.prepend(ActiveRecordReadOnly::Behavior)
      marker = Module.new
      marker.define_singleton_method(:__active_record_read_only_class__) { klass }
      marker.define_singleton_method(:included) do |_base|
        loc = caller_locations(1, 8).find { |l| l.path && l.path != __FILE__ }
        ActiveRecordReadOnly::Registry.allow(klass, loc.path) if loc
      end
      klass.const_set(:Writable, marker)
    end
  end
end
