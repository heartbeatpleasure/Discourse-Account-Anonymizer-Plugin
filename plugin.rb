# frozen_string_literal: true

# name: Discourse-Account-Anonymizer-Plugin
# about: Allows eligible users with existing content to permanently anonymize and deactivate their own account.
# version: 1.0.2
# authors: HeartbeatPleasure
# url: https://github.com/heartbeatpleasure/Discourse-Account-Anonymizer-Plugin
# required_version: 3.5.0

enabled_site_setting :account_anonymizer_enabled
register_asset "stylesheets/common/account-anonymizer.scss"

module ::DiscourseAccountAnonymizer
  PLUGIN_NAME = "Discourse-Account-Anonymizer-Plugin"
end

after_initialize do
  require_relative "lib/discourse_account_anonymizer/compatibility"
  require_relative "lib/discourse_account_anonymizer/policy"
  require_relative "lib/discourse_account_anonymizer/user_anonymizer"
  require_relative "app/services/discourse_account_anonymizer/anonymize_account"
  require_relative "app/controllers/discourse_account_anonymizer/account_controller"

  add_to_serializer(:current_user, :can_self_anonymize_account) do
    DiscourseAccountAnonymizer::Policy.new(user: object, guardian: scope).allowed?
  end

  Discourse::Application.routes.append do
    post "/account-anonymizer/anonymize" =>
           "discourse_account_anonymizer/account#anonymize"
  end
end
