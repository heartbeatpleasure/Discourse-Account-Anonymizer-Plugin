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
      return :disabled unless SiteSetting.account_anonymizer_enabled
      return :missing_user if user.blank?
      return :incompatible unless Compatibility.compatible?
      return :invalid_username_prefix unless Compatibility.valid_username_prefix?(user)
      return :staff if user.staff?
      return :impersonating if user.respond_to?(:is_impersonating) && user.is_impersonating
      return :anonymous if user.anonymous?
      return :staged if user.staged?
      return :inactive unless user.active?
      return :unapproved if SiteSetting.must_approve_users && !user.approved?
      return :suspended if user.suspended?
      return :silenced if user.silenced?
      return :no_password unless user.has_password?
      return :unsupported_auth if SiteSetting.enable_discourse_connect || !SiteSetting.enable_local_logins
      return :already_anonymized if anonymized?
      return :native_delete_available if guardian.can_delete_user?(user)
      return :no_content unless user.has_more_posts_than?(0)
      return :group_owner if owns_group?
      return :pending_review if pending_review?

      nil
    end

    private

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
