# frozen_string_literal: true

module DiscourseAccountAnonymizer
  module Compatibility
    module_function

    def compatible?
      return false unless defined?(::UserAnonymizer)
      return false unless defined?(::UsernameChanger)
      return false unless ::UserAnonymizer.const_defined?(:EMAIL_SUFFIX)

      anonymize_method = ::UserAnonymizer.instance_method(:make_anonymous)
      username_method = ::UserAnonymizer.instance_method(:make_anon_username)

      anonymize_method.arity == 0 && username_method.arity == 0
    rescue NameError
      false
    end

    def valid_username_prefix?(user)
      prefix = SiteSetting.account_anonymizer_username_prefix.to_s
      return false if prefix.blank?

      candidate = "#{prefix}00000000"
      validator = UsernameValidator.new(candidate, object: user)

      validator.valid_format? && !User.reserved_username?(candidate)
    rescue StandardError
      false
    end
  end
end
