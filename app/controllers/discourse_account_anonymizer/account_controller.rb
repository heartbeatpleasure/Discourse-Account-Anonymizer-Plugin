# frozen_string_literal: true

module DiscourseAccountAnonymizer
  class AccountController < ::ApplicationController
    requires_plugin DiscourseAccountAnonymizer::PLUGIN_NAME
    requires_login

    USER_ATTEMPTS = 5
    IP_ATTEMPTS = 20
    RATE_LIMIT_WINDOW = 15.minutes

    def anonymize
      raise Discourse::NotFound unless SiteSetting.account_anonymizer_enabled
      raise Discourse::InvalidAccess.new if is_api?

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
