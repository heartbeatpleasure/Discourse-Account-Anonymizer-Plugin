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

    def has_content?
      user.present? && user.has_more_posts_than?(0)
    end

    def native_self_delete_blocked?
      common_reason.present? || has_content?
    end

    def native_delete_allowed?
      return false if native_self_delete_blocked?

      guardian.can_delete_user?(user)
    end

    def reason
      return common_reason if common_reason.present?
      return :no_content unless has_content?
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
        elsif anonymized?
          :already_anonymized
        elsif owns_group?
          :group_owner
        elsif pending_review?
          :pending_review
        end
    end

    def anonymized?
      user.email&.ends_with?(::UserAnonymizer::EMAIL_SUFFIX)
    end

    def owns_group?
      GroupUser.where(user_id: user.id, owner: true).exists?
    end

    def pending_review?
      Reviewable.pending.where(target_created_by_id: user.id).exists? ||
        ReviewableUser.pending.where(target: user).exists?
    end
  end
end
