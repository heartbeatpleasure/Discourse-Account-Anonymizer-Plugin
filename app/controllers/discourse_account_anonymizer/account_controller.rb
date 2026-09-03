# frozen_string_literal: true

module DiscourseAccountAnonymizer
  class AccountController < ::ApplicationController
    requires_plugin DiscourseAccountAnonymizer::PLUGIN_NAME
    requires_login
    before_action :ensure_browser_session!

    USER_ATTEMPTS = 5
    IP_ATTEMPTS = 20
    RATE_LIMIT_WINDOW = 15.minutes

    def status
      raise Discourse::NotFound unless SiteSetting.account_anonymizer_enabled

      policy = Policy.new(user: current_user, guardian: guardian)

      mode =
        if policy.has_content?
          policy.allowed? ? "anonymize" : "unavailable"
        elsif policy.native_delete_allowed?
          "native_delete"
        else
          "unavailable"
        end

      render json: { mode: mode }
    end

    def anonymize
      raise Discourse::NotFound unless SiteSetting.account_anonymizer_enabled

      password = params.require(:password).to_s
      if password.length > User.max_password_length
        return render_json_error(
                 I18n.t("account_anonymizer.errors.password_too_long"),
                 status: :unprocessable_entity,
               )
      end

      rate_limit!

      AnonymizeAccount.new(user: current_user, password: password).call
      render json: success_json
    rescue AnonymizeAccount::InvalidPassword
      render_json_error(
        I18n.t("account_anonymizer.errors.incorrect_password"),
        status: :unprocessable_entity,
      )
    rescue Discourse::InvalidAccess
      render_json_error(
        I18n.t("account_anonymizer.errors.unavailable"),
        status: :forbidden,
      )
    end

    private

    def ensure_browser_session!
      raise Discourse::InvalidAccess.new if is_api? || is_user_api?
    end

    def rate_limit!
      RateLimiter.new(
        current_user,
        "account-anonymizer-password",
        USER_ATTEMPTS,
        RATE_LIMIT_WINDOW,
      ).performed!

      RateLimiter.new(
        nil,
        "account-anonymizer-password-ip-#{request.remote_ip}",
        IP_ATTEMPTS,
        RATE_LIMIT_WINDOW,
      ).performed!
    end
  end
end
