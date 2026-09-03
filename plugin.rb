# frozen_string_literal: true

# name: discourse-account-anonymizer
# about: Allows eligible users to permanently anonymize and deactivate their own account without self-service hard deletion.
# version: 1.0.7
# authors: HeartbeatPleasure
# url: https://github.com/heartbeatpleasure/discourse-account-anonymizer
# required_version: 3.5.0

# Do not use enabled_site_setting here. The setting controls whether NEW
# self-service requests are allowed, but lifecycle protections for accounts
# already anonymized by this plugin must remain active while the plugin is
# installed, even if self-service is later switched off.

module ::DiscourseAccountAnonymizer
  PLUGIN_NAME = "discourse-account-anonymizer"
end

after_initialize do
  require_relative "lib/discourse_account_anonymizer/compatibility"
  require_relative "lib/discourse_account_anonymizer/state"
  require_relative "lib/discourse_account_anonymizer/policy"
  require_relative "lib/discourse_account_anonymizer/guardian_extension"
  require_relative "lib/discourse_account_anonymizer/user_anonymizer"
  require_relative "app/services/discourse_account_anonymizer/anonymize_account"
  require_relative "app/controllers/discourse_account_anonymizer/account_controller"

  reloadable_patch do
    Guardian.prepend(DiscourseAccountAnonymizer::GuardianExtension)
  end

  # A self-anonymized account is an irreversible lifecycle state. Core
  # activation paths (email tokens, passwordless login, admin activation, etc.)
  # all persist active=true through normal model validation, so reject that
  # transition for accounts that carry the self-anonymization history marker.
  #
  # This protection intentionally remains active even when the site setting is
  # disabled: disabling self-service must not resurrect accounts that were
  # already permanently anonymized.
  add_model_callback(User, :before_validation) do
    next unless will_save_change_to_active? && active?
    next unless DiscourseAccountAnonymizer::State.self_anonymization_history?(id)

    errors.add(:active, I18n.t("account_anonymizer.errors.irreversible"))
  end

  # If IP anonymization is enabled, prevent a deferred request activity update
  # from writing the just-used browser IP back after the core anonymizer has
  # committed. Discourse intentionally exposes this modifier around
  # User.update_ip_address!, so use that extension point rather than patching
  # the core method. Preserve the incoming modifier value to compose safely
  # with other plugins.
  register_modifier(:user_can_update_ip_address) do |permission|
    next permission unless SiteSetting.account_anonymizer_anonymize_ip
    next permission unless permission.is_a?(Hash)

    user_id = permission[:user_id] || permission["user_id"]
    next permission if user_id.blank?

    if DiscourseAccountAnonymizer::State.self_anonymization_history?(user_id)
      false
    else
      permission
    end
  end

  # Discourse's CleanUpInactiveUsers job can hard-delete old TL0 users without
  # posts/topics/bookmarks. Protect already self-anonymized accounts from that
  # cleanup even when they never created normal forum content.
  #
  # This is an official Discourse extension point used by core plugins such as
  # Poll for the same purpose.
  register_modifier(:clean_up_inactive_users_query) do |relation|
    relation.where(<<~SQL.squish)
      NOT EXISTS (
        SELECT 1
        FROM user_histories account_anonymizer_history
        WHERE account_anonymizer_history.target_user_id = users.id
          AND account_anonymizer_history.acting_user_id = users.id
          AND account_anonymizer_history.action = #{UserHistory.actions[:anonymize_user]}
      )
    SQL
  end

  Discourse::Application.routes.append do
    get "/account-anonymizer/status" => "discourse_account_anonymizer/account#status"
    post "/account-anonymizer/anonymize" => "discourse_account_anonymizer/account#anonymize"
  end
end
