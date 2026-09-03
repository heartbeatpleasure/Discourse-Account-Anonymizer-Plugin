# frozen_string_literal: true

module DiscourseAccountAnonymizer
  class AnonymizeAccount
    class InvalidPassword < StandardError
    end

    LOCK_VALIDITY = 5.minutes

    def initialize(user:, password:)
      @user = user
      @password = password.to_s
      @original_emails = []
      @login_emails = []
    end

    def call
      DistributedMutex.synchronize(lock_key, validity: LOCK_VALIDITY) do
        @user.reload

        # A duplicate/concurrent request can arrive after the core anonymizer
        # committed and replaced the password. The self-anonymization history
        # is written inside that same core transaction, so it is a stronger
        # idempotence marker than an email suffix that a normal account could
        # theoretically use on its own.
        if State.self_anonymization_history?(@user)
          # If a legacy/in-flight email flow restored an address after the core
          # transaction, remember it so passwordless login codes for that
          # address are also revoked during repair.
          unless State.anonymized_email?(@user)
            @original_emails |= [@user.email]
            @login_emails |= [@user.email]
          end

          finalize_anonymized_account!
          return true
        end

        policy = Policy.new(user: @user)
        raise Discourse::InvalidAccess.new unless policy.allowed?
        raise InvalidPassword unless @user.confirm_password?(@password)

        # Re-read the account immediately before the irreversible core call.
        # This narrows races with concurrent moderation/role/account-state
        # changes that may have happened while the password hash was checked.
        @user.reload
        raise Discourse::InvalidAccess.new unless Policy.new(user: @user).allowed?

        @original_emails = previous_emails
        @login_emails = current_login_emails

        # EmailToken.confirm can activate a user and restore the token's email.
        # Core removes these tokens only in the asynchronous anonymize_user job,
        # so revoke them synchronously before anonymization. Also invalidate
        # passwordless email-login codes for the old addresses.
        revoke_reactivation_credentials!

        # Credential revocation itself is deliberately before the irreversible
        # core call. Re-check eligibility one final time afterwards so a role,
        # moderation, approval, or feature-setting change racing this request
        # cannot slip through merely because it happened during token cleanup.
        @user.reload
        raise Discourse::InvalidAccess.new unless Policy.new(user: @user).allowed?
        raise InvalidPassword unless @user.confirm_password?(@password)

        @original_emails |= previous_emails
        @login_emails |= current_login_emails
        original_username = @user.username
        options = anonymizer_options

        begin
          UserAnonymizer.new(@user, @user, options).make_anonymous
        rescue StandardError => error
          @user.reload

          # UserAnonymizer writes its anonymize_user history in the same
          # transaction as the username/email/password changes. If that marker
          # exists, the privacy-critical transaction committed even if a later
          # username-update enqueue or :user_anonymized listener raised.
          raise unless State.self_anonymization_history?(@user)

          Discourse.warn_exception(
            error,
            message: "[discourse-account-anonymizer] post-commit anonymizer failure for user #{@user.id}",
          )

          reenqueue_core_cleanup(original_username, @original_emails, options)
        end

        finalize_anonymized_account!
        true
      end
    end

    private

    def lock_key
      "discourse-account-anonymizer:user:#{@user.id}"
    end

    def previous_emails
      UserEmail.where(user_id: @user.id).pluck(:email) |
        UserAssociatedAccount
          .where(user_id: @user.id)
          .pluck(Arel.sql("info->>'email'"))
          .compact
    end

    def current_login_emails
      UserEmail.where(user_id: @user.id).pluck(:email)
    end

    def anonymizer_options
      return {} unless SiteSetting.account_anonymizer_anonymize_ip

      { anonymize_ip: "0.0.0.0" }
    end

    def finalize_anonymized_account!
      @user.reload

      unless State.self_anonymization_history?(@user)
        raise "Account anonymization history is missing; refusing irreversible finalization"
      end

      # Everything below runs after the core anonymizer transaction committed.
      # Do not turn a partial finalization problem into a user-visible retry of
      # an already irreversible operation. Each safety step is independently
      # best-effort, logged, and followed by residual credential revocation.
      repair_anonymized_email_if_needed!
      verify_anonymized_state!

      begin
        deactivate_user_with_purge_protection!
      rescue StandardError => error
        # The deactivation transaction guarantees that a failed protective
        # history write cannot leave an inactive-but-purgeable zero-content
        # account. CleanUpInactiveUsers is independently guarded by the plugin's
        # query modifier using the core anonymize_user history marker.
        Discourse.warn_exception(
          error,
          message: "[discourse-account-anonymizer] critical deactivation finalization failure for user #{@user.id}; account remains anonymized and inaccessible",
        )
      ensure
        revoke_residual_credentials!
      end
    end

    def repair_anonymized_email_if_needed!
      return if State.anonymized_email?(@user)

      primary_email = @user.primary_email
      if primary_email.blank?
        Rails.logger.error(
          "[discourse-account-anonymizer] anonymized user #{@user.id} has no primary email record; unable to restore anonymized email",
        )
        return
      end

      expected_email = "#{@user.username}#{::UserAnonymizer::EMAIL_SUFFIX}"

      # A concurrently finishing email-confirmation flow can theoretically
      # restore an old address after the core transaction commits. The history
      # marker proves anonymization already happened, so restoring an invalid
      # anonymized address is fail-safe and does not require the obsolete
      # password.
      begin
        primary_email.update_columns(email: expected_email, normalized_email: expected_email)
      rescue StandardError => error
        # A uniqueness conflict on the canonical address should never normally
        # occur, but privacy is more important than preserving that cosmetic
        # convention. Fall back to a fresh non-deliverable address.
        fallback_email =
          "deleted-#{@user.id}-#{SecureRandom.hex(12)}#{::UserAnonymizer::EMAIL_SUFFIX}"

        Discourse.warn_exception(
          error,
          message: "[discourse-account-anonymizer] failed to restore canonical anonymized email for user #{@user.id}; applying privacy fallback",
        )

        begin
          primary_email.update_columns(email: fallback_email, normalized_email: fallback_email)
        rescue StandardError => fallback_error
          Discourse.warn_exception(
            fallback_error,
            message: "[discourse-account-anonymizer] critical failure restoring anonymized email for user #{@user.id}",
          )
        end
      ensure
        @user.reload
      end
    end

    def verify_anonymized_state!
      unless State.committed_self_anonymization?(@user)
        Rails.logger.error(
          "[discourse-account-anonymizer] self-anonymization history exists but user #{@user.id} is not using an anonymized email; continuing access lockdown",
        )
      end

      prefix = SiteSetting.account_anonymizer_username_prefix.to_s
      return if @user.username.start_with?(prefix)

      # A future Discourse change or a concurrent setting change must not leave
      # a committed anonymized account active merely because the cosmetic
      # username prefix differs from the current configuration.
      Rails.logger.error(
        "[discourse-account-anonymizer] anonymized username prefix mismatch for user #{@user.id}; continuing safe finalization",
      )
    end

    def deactivate_user_with_purge_protection!
      User.transaction do
        @user.reload
        ensure_deactivation_history!
        deactivate_active_flag! if @user.active?
      end
    end

    def ensure_deactivation_history!
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
    end

    def deactivate_active_flag!
      # Do not call User#deactivate here. Core can route a pending ReviewableUser
      # from that method into UserDestroyer. This plugin must never have a path
      # that deletes a User record or their content.
      begin
        @user.update!(active: false)
      rescue StandardError => error
        # A plugin-added validation can make a normal save fail. Because the
        # protective history is created first in this same transaction, the
        # narrowly scoped fallback cannot leave a purgeable inactive account.
        Discourse.warn_exception(
          error,
          message: "[discourse-account-anonymizer] normal deactivation failed for user #{@user.id}; applying safe fallback",
        )
        @user.update_column(:active, false)
        @user.anonymous_user_shadows.update_all(active: false)
      end
    end

    def revoke_reactivation_credentials!
      EmailToken.where(user_id: @user.id).destroy_all
      revoke_email_login_codes!
    end

    def revoke_residual_credentials!
      # Core already removes UserAuthToken records synchronously. Repeating the
      # session/reactivation-sensitive cleanup after finalization closes the
      # narrow window in which a concurrently finishing reset/login flow could
      # have created fresh credentials while anonymization was in progress.
      EmailToken.where(user_id: @user.id).destroy_all
      UserAuthToken.where(user_id: @user.id).destroy_all
      revoke_email_login_codes!
    rescue StandardError => error
      Discourse.warn_exception(
        error,
        message: "[discourse-account-anonymizer] failed to revoke residual credentials for user #{@user.id}",
      )
    end

    def revoke_email_login_codes!
      emails = @login_emails.compact.map { |email| email.to_s.downcase }.reject(&:blank?).uniq
      return if emails.empty?
      return unless defined?(::EmailLoginCode)

      EmailLoginCode.where("lower(email) IN (?)", emails).delete_all
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
