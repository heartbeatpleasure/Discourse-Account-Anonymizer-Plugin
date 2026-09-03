# frozen_string_literal: true

module DiscourseAccountAnonymizer
  # Harden Discourse's existing self-delete authorization so the plugin's
  # server-side invariants cannot be bypassed by calling the core user delete
  # endpoint directly.
  #
  # This extension is deliberately narrow: it only changes authorization when
  # the acting user is also the target user. Staff actions against other users
  # and all other Guardian behavior continue through Discourse core unchanged.
  module GuardianExtension
    def can_delete_user?(target_user)
      if SiteSetting.account_anonymizer_enabled && target_user.present? && is_me?(target_user)
        return false if account_anonymizer_api_request?

        policy = DiscourseAccountAnonymizer::Policy.new(user: target_user, guardian: self)
        return false if policy.native_self_delete_blocked?
      end

      super
    end

    private

    def account_anonymizer_api_request?
      return false if request.blank?

      request.env[Auth::DefaultCurrentUserProvider::API_KEY_ENV] ||
        request.env[Auth::DefaultCurrentUserProvider::USER_API_KEY_ENV]
    end
  end
end
