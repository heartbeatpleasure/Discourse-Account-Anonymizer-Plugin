# frozen_string_literal: true

# name: discourse-account-anonymizer
# about: Allows eligible users with existing content to permanently anonymize and deactivate their own account.
# version: 1.0.5
# authors: HeartbeatPleasure
# url: https://github.com/heartbeatpleasure/discourse-account-anonymizer
# required_version: 3.5.0

enabled_site_setting :account_anonymizer_enabled

module ::DiscourseAccountAnonymizer
  PLUGIN_NAME = "discourse-account-anonymizer"
end

after_initialize do
  require_relative "lib/discourse_account_anonymizer/compatibility"
  require_relative "lib/discourse_account_anonymizer/policy"
  require_relative "lib/discourse_account_anonymizer/guardian_extension"
  require_relative "lib/discourse_account_anonymizer/user_anonymizer"
  require_relative "app/services/discourse_account_anonymizer/anonymize_account"
  require_relative "app/controllers/discourse_account_anonymizer/account_controller"

  reloadable_patch do
    Guardian.prepend(DiscourseAccountAnonymizer::GuardianExtension)
  end

  Discourse::Application.routes.append do
    get "/account-anonymizer/status" => "discourse_account_anonymizer/account#status"
    post "/account-anonymizer/anonymize" => "discourse_account_anonymizer/account#anonymize"
  end
end
