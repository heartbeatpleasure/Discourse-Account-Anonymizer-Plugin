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
  end
end
