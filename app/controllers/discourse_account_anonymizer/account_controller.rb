# frozen_string_literal: true

module DiscourseAccountAnonymizer
  class AccountController < ::ApplicationController
    requires_plugin DiscourseAccountAnonymizer::PLUGIN_NAME
    requires_login
    before_action :ensure_browser_session!
    skip_after_action :perform_refresh_session, only: :anonymize, raise: false

    USER_ATTEMPTS = 5
    IP_ATTEMPTS = 20
    RATE_LIMIT_WINDOW = 15.minutes

    def status
      raise Discourse::NotFound unless SiteSetting.account_anonymizer_enabled

      policy = Policy.new(user: current_user, guardian: guardian)
      render json: { mode: policy.allowed? ? "anonymize" : "unavailable" }
    end

    def anonymize
      raise Discourse::NotFound unless SiteSetting.account_anonymizer_enabled

      # Passwords are accepted only from the request body. Keeping credentials
      # out of the query string avoids accidental exposure through URLs,
      # browser history, proxies, or request-URI logging.
      raise Discourse::InvalidParameters.new(:password) if request.query_parameters.key?("password")

      password = params.require(:password)
      raise Discourse::InvalidParameters.new(:password) unless password.is_a?(String)

      if password.length > User.max_password_length
        return render_json_error(
                 I18n.t("account_anonymizer.errors.password_too_long"),
                 status: :unprocessable_entity,
               )
      end

      rate_limit!

      AnonymizeAccount.new(user: current_user, password: password).call

      # Core anonymization destroys every UserAuthToken. Do not let the
      # inherited session-refresh after_action touch the now-destroyed request
      # token. Also clear the browser's Rails session, mirroring normal logout,
      # so trusted-session or other account-scoped state cannot bleed into a
      # later login in the same browser. Cleanup is best-effort because the
      # irreversible server-side operation has already succeeded.
      clear_browser_session_state!
      clear_browser_auth_cookies!

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
      # Discourse deliberately treats API and User API credentials differently
      # from browser sessions (including bypassing browser CSRF checks). This
      # destructive self-service flow therefore requires the concrete
      # UserAuthToken that core resolved from the normal browser auth cookie.
      # Shared-session authentication does not populate this env slot and is
      # intentionally rejected as well.
      raise Discourse::InvalidAccess.new if is_api? || is_user_api?

      provider = Auth::DefaultCurrentUserProvider
      unless provider.const_defined?(:USER_TOKEN_KEY, false)
        raise Discourse::InvalidAccess.new
      end

      auth_token = request.env[provider::USER_TOKEN_KEY]
      unless auth_token&.user_id == current_user.id
        raise Discourse::InvalidAccess.new
      end
    end

    def clear_browser_session_state!
      reset_session
    rescue StandardError => error
      Discourse.warn_exception(
        error,
        message: "[discourse-account-anonymizer] failed to reset browser session after successful anonymization for user #{current_user.id}",
      )
    end

    def clear_browser_auth_cookies!
      cookies.delete("authentication_data")

      provider = Auth::DefaultCurrentUserProvider
      cookies.delete(provider::TOKEN_COOKIE) if provider.const_defined?(:TOKEN_COOKIE, false)
    rescue StandardError => error
      Discourse.warn_exception(
        error,
        message: "[discourse-account-anonymizer] failed to clear stale browser auth cookies after successful anonymization for user #{current_user.id}",
      )
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
