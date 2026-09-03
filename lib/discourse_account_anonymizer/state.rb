# frozen_string_literal: true

module DiscourseAccountAnonymizer
  module State
    module_function

    def self_anonymization_history?(user_or_id)
      user_id = user_or_id.respond_to?(:id) ? user_or_id.id : user_or_id
      return false if user_id.blank?

      UserHistory.exists?(
        action: UserHistory.actions[:anonymize_user],
        target_user_id: user_id,
        acting_user_id: user_id,
      )
    end

    def anonymized_email?(user)
      user.present? && user.email&.ends_with?(::UserAnonymizer::EMAIL_SUFFIX)
    end

    def committed_self_anonymization?(user)
      anonymized_email?(user) && self_anonymization_history?(user)
    end
  end
end
