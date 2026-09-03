# frozen_string_literal: true

module DiscourseAccountAnonymizer
  class AnonymizeAccount
    class InvalidPassword < StandardError
    end

    LOCK_VALIDITY = 5.minutes

    def initialize(user:, password:)
      @user = user
      @password = password.to_s
    end

    def call
      DistributedMutex.synchronize(lock_key, validity: LOCK_VALIDITY) do
        @user.reload

        return true if already_completed?

        policy = Policy.new(user: @user)
        raise Discourse::InvalidAccess.new unless policy.allowed?
        raise InvalidPassword unless @user.confirm_password?(@password)

        original_username = @user.username
        original_emails = previous_emails
        options = anonymizer_options

        begin
          UserAnonymizer.new(@user, @user, options).make_anonymous
        rescue StandardError => error
          @user.reload

          # UserAnonymizer commits its main transaction before it enqueues its
          # background work and triggers :user_anonymized. If something fails
          # after that commit, the account is already irreversibly anonymized.
          # Finish deactivation rather than returning a misleading retry path.
          raise unless anonymized?

          Discourse.warn_exception(
            error,
            message: "[discourse-account-anonymizer] post-commit anonymizer failure for user #{@user.id}",
          )

          reenqueue_core_cleanup(original_username, original_emails, options)
        end

        @user.reload
        verify_anonymized_state!
        deactivate_user!

        true
      end
    end

    private

    def lock_key
      "discourse-account-anonymizer:user:#{@user.id}"
    end

    def already_completed?
      anonymized? && !@user.active?
    end

    def anonymized?
      @user.email&.ends_with?(::UserAnonymizer::EMAIL_SUFFIX)
    end

    def previous_emails
      UserEmail.where(user_id: @user.id).pluck(:email) |
        UserAssociatedAccount
          .where(user_id: @user.id)
          .pluck(Arel.sql("info->>'email'"))
          .compact
    end

    def anonymizer_options
      return {} unless SiteSetting.account_anonymizer_anonymize_ip

      { anonymize_ip: "0.0.0.0" }
    end

    def verify_anonymized_state!
      prefix = SiteSetting.account_anonymizer_username_prefix.to_s

      unless anonymized? && @user.username.start_with?(prefix)
        raise "Account anonymization did not reach the expected final state"
      end
    end

    def deactivate_user!
      return log_deactivation_history unless @user.active?

      # Do not call User#deactivate here. That method can route a pending
      # ReviewableUser into UserDestroyer. This plugin must never have a path
      # that deletes a User record or their content.
      begin
        @user.update!(active: false)
      rescue StandardError => error
        # The account is already anonymized at this point. If a plugin-added
        # validation prevents a normal save, fail closed with a narrowly scoped
        # update of the active flag rather than leaving the anonymized account
        # visible as an active community user.
        Discourse.warn_exception(
          error,
          message: "[discourse-account-anonymizer] normal deactivation failed for user #{@user.id}; applying safe fallback",
        )
        @user.update_column(:active, false)
        @user.anonymous_user_shadows.update_all(active: false)
      end

      log_deactivation_history
    end

    def log_deactivation_history
      return if UserHistory.exists?(
        action: UserHistory.actions[:deactivate_user],
        target_user_id: @user.id,
        acting_user_id: @user.id,
      )

      UserHistory.create!(
        action: UserHistory.actions[:deactivate_user],
        target_user_id: @user.id,
        acting_user_id: @user.id,
        details: I18n.t("account_anonymizer.deactivated_by_self_service"),
      )
    rescue StandardError => error
      # The account is already anonymized and inactive. The history record is
      # useful for auditability and protects it from the unactivated-user purge,
      # but failure to write the audit record must not create a retry path for
      # an operation that has already completed.
      Discourse.warn_exception(
        error,
        message: "[discourse-account-anonymizer] failed to write deactivation history for user #{@user.id}",
      )
    end

    def reenqueue_core_cleanup(original_username, original_emails, options)
      begin
        UsernameChanger.update_username(
          user_id: @user.id,
          old_username: original_username,
          new_username: @user.username,
          avatar_template: @user.avatar_template,
        )

        Jobs.enqueue(
          :anonymize_user,
          user_id: @user.id,
          prev_emails: original_emails,
          prev_username: original_username,
          anonymize_ip: options[:anonymize_ip],
        )
      rescue StandardError => cleanup_error
        Discourse.warn_exception(
          cleanup_error,
          message: "[discourse-account-anonymizer] failed to re-enqueue core cleanup for user #{@user.id}",
        )
      end
    end
  end
end
