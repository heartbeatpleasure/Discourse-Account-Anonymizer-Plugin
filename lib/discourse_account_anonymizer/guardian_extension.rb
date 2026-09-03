# frozen_string_literal: true

module DiscourseAccountAnonymizer
  # Hard self-deletion is intentionally disabled while this plugin is loaded.
  # Every self-service account removal must preserve the User record and go
  # through anonymization; disabling the feature setting merely stops new
  # self-service anonymization requests and must not silently restore a hard
  # delete path.
  #
  # This extension is deliberately narrow: it only changes authorization when
  # the acting user is also the target user. Staff actions against other users
  # and all other Guardian behavior continue through Discourse core unchanged.
  module GuardianExtension
    def can_delete_user?(target_user)
      return false if target_user.present? && is_me?(target_user)

      super
    end

    # The model-level activation guard remains the final safety net, but core
    # admin UI/API authorization should also report the irreversible state
    # correctly. This prevents staff from being offered an Activate action that
    # can only fail, without changing activation permissions for normal inactive
    # accounts.
    def can_activate?(target_user)
      if is_staff? && target_user.present? && !target_user.active? &&
           DiscourseAccountAnonymizer::State.self_anonymization_history?(target_user)
        return false
      end

      super
    end
  end
end
