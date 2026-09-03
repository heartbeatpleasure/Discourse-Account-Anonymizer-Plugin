# frozen_string_literal: true

module DiscourseAccountAnonymizer
  class Policy
    attr_reader :user, :guardian

    def initialize(user:, guardian: nil)
      @user = user
      @guardian = guardian || Guardian.new(user)
    end

    def allowed?
      reason.nil?
    end

    def reason
      return common_reason if common_reason.present?
      return :incompatible unless Compatibility.compatible?
      return :invalid_username_prefix unless Compatibility.valid_username_prefix?(user)
      return :no_password unless user.has_password?
      return :unsupported_auth if SiteSetting.enable_discourse_connect || !SiteSetting.enable_local_logins

      nil
    end

    private

    def common_reason
      return @common_reason if defined?(@common_reason)

      @common_reason =
        if !SiteSetting.account_anonymizer_enabled
          :disabled
        elsif user.blank?
          :missing_user
        elsif user.staff?
          :staff
        elsif user.respond_to?(:is_impersonating) && user.is_impersonating
          :impersonating
        elsif user.anonymous?
          :anonymous
        elsif user.staged?
          :staged
        elsif !user.active?
          :inactive
        elsif SiteSetting.must_approve_users && !user.approved?
          :unapproved
        elsif user.suspended?
          :suspended
        elsif user.silenced?
          :silenced
        elsif State.self_anonymization_history?(user)
          :already_anonymized
        elsif pending_account_review?
          :pending_account_review
        end
    end

    def pending_account_review?
      ReviewableUser.pending.where(target: user).exists?
    end
  end
end
