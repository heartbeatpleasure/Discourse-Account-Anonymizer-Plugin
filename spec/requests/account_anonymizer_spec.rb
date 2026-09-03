# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Account Anonymizer" do
  fab!(:user) { Fabricate(:user, password: "correct-password") }
  fab!(:other_user) { Fabricate(:user, password: "other-password") }
  fab!(:post_record) { Fabricate(:post, user: user) }

  before do
    SiteSetting.account_anonymizer_enabled = true
    SiteSetting.account_anonymizer_username_prefix = "Deleted-"
    SiteSetting.account_anonymizer_anonymize_ip = false
    SiteSetting.enable_local_logins = true
    SiteSetting.enable_discourse_connect = false
    SiteSetting.delete_user_self_max_post_count = 0
    sign_in(user)
  end

  describe "GET /account-anonymizer/status.json" do
    it "returns anonymize for an eligible user with content" do
      get "/account-anonymizer/status.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["mode"]).to eq("anonymize")
    end

    it "returns anonymize for a truly content-free account" do
      empty_user = Fabricate(:user, password: "correct-password")
      sign_in(empty_user)
      SiteSetting.delete_user_self_max_post_count = 100

      get "/account-anonymizer/status.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["mode"]).to eq("anonymize")
    end

    it "does not change mode when content is added to an already eligible account" do
      fresh_user = Fabricate(:user, password: "correct-password")
      sign_in(fresh_user)

      get "/account-anonymizer/status.json"
      expect(response.parsed_body["mode"]).to eq("anonymize")

      3.times { Fabricate(:post, user: fresh_user) }

      get "/account-anonymizer/status.json"
      expect(response.parsed_body["mode"]).to eq("anonymize")
    end

    it "returns unavailable for staff" do
      user.update!(moderator: true)

      get "/account-anonymizer/status.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["mode"]).to eq("unavailable")
    end
  end

  it "anonymizes and deactivates only the current user while preserving content" do
    original_user_id = user.id
    original_post_id = post_record.id
    original_other_username = other_user.username

    post "/account-anonymizer/anonymize.json", params: { password: "correct-password" }

    expect(response.status).to eq(200)

    user.reload
    expect(user.id).to eq(original_user_id)
    expect(user.username).to start_with("Deleted-")
    expect(user.email).to end_with(UserAnonymizer::EMAIL_SUFFIX)
    expect(user.active).to eq(false)

    preserved_post = Post.with_deleted.find(original_post_id)
    expect(preserved_post.user_id).to eq(original_user_id)
    expect(other_user.reload.username).to eq(original_other_username)
    expect(
      UserHistory.exists?(
        action: UserHistory.actions[:deactivate_user],
        target_user_id: original_user_id,
        acting_user_id: original_user_id,
      ),
    ).to eq(true)
  end

  it "anonymizes and deactivates a content-free account rather than hard deleting it" do
    empty_user = Fabricate(:user, password: "correct-password")
    original_id = empty_user.id
    sign_in(empty_user)

    post "/account-anonymizer/anonymize.json", params: { password: "correct-password" }

    expect(response.status).to eq(200)
    expect(User.exists?(original_id)).to eq(true)

    empty_user.reload
    expect(empty_user.username).to start_with("Deleted-")
    expect(empty_user.email).to end_with(UserAnonymizer::EMAIL_SUFFIX)
    expect(empty_user.active).to eq(false)
  end

  it "protects an old zero-content anonymized account from Discourse unactivated-user purging" do
    SiteSetting.purge_unactivated_users_grace_period_days = 1
    empty_user = Fabricate(:user, password: "correct-password", created_at: 30.days.ago)
    original_id = empty_user.id
    sign_in(empty_user)

    post "/account-anonymizer/anonymize.json", params: { password: "correct-password" }
    expect(response.status).to eq(200)

    User.purge_unactivated

    expect(User.exists?(original_id)).to eq(true)
    expect(User.find(original_id).active).to eq(false)
  end

  it "protects an old zero-content anonymized account from CleanUpInactiveUsers even after self-service is disabled" do
    SiteSetting.clean_up_inactive_users_after_days = 1
    empty_user = Fabricate(:user, password: "correct-password")
    original_id = empty_user.id
    sign_in(empty_user)

    post "/account-anonymizer/anonymize.json", params: { password: "correct-password" }
    expect(response.status).to eq(200)

    empty_user.reload.update_columns(
      created_at: 30.days.ago,
      last_seen_at: 30.days.ago,
      last_posted_at: nil,
      trust_level: TrustLevel.levels[:newuser],
    )

    # Existing deleted accounts remain protected even if self-service is later
    # turned off. The setting controls new requests, not lifecycle integrity of
    # accounts that were already irreversibly anonymized.
    SiteSetting.account_anonymizer_enabled = false
    Jobs::CleanUpInactiveUsers.new.execute({})

    expect(User.exists?(original_id)).to eq(true)
    expect(User.find(original_id).active).to eq(false)
  end

  it "does not exempt ordinary old users from Discourse CleanUpInactiveUsers" do
    SiteSetting.clean_up_inactive_users_after_days = 1
    ordinary_user = Fabricate(:user)
    ordinary_id = ordinary_user.id
    ordinary_user.update_columns(
      created_at: 30.days.ago,
      last_seen_at: 30.days.ago,
      last_posted_at: nil,
      trust_level: TrustLevel.levels[:newuser],
    )

    Jobs::CleanUpInactiveUsers.new.execute({})

    expect(User.exists?(ordinary_id)).to eq(false)
  end

  it "preserves private-message content and participants" do
    pm_post =
      PostCreator.create!(
        user,
        title: "Private conversation",
        raw: "This private message must remain intact.",
        archetype: Archetype.private_message,
        target_usernames: [other_user.username],
      )
    pm_topic_id = pm_post.topic_id

    post "/account-anonymizer/anonymize.json", params: { password: "correct-password" }

    expect(response.status).to eq(200)
    expect(Post.with_deleted.find(pm_post.id).user_id).to eq(user.id)
    expect(Topic.find(pm_topic_id).archetype).to eq(Archetype.private_message)
    expect(TopicAllowedUser.where(topic_id: pm_topic_id, user_id: other_user.id)).to exist
  end

  it "does not accept a request parameter as the target user" do
    post "/account-anonymizer/anonymize.json",
         params: { password: "correct-password", user_id: other_user.id, username: other_user.username }

    expect(response.status).to eq(200)
    expect(user.reload.username).to start_with("Deleted-")
    expect(other_user.reload.email).not_to end_with(UserAnonymizer::EMAIL_SUFFIX)
    expect(other_user.active).to eq(true)
  end

  it "makes no changes when the password is incorrect" do
    original_username = user.username
    original_email = user.email

    post "/account-anonymizer/anonymize.json", params: { password: "wrong-password" }

    expect(response.status).to eq(422)
    user.reload
    expect(user.username).to eq(original_username)
    expect(user.email).to eq(original_email)
    expect(user.active).to eq(true)
  end

  it "blocks staff" do
    user.update!(moderator: true)

    post "/account-anonymizer/anonymize.json", params: { password: "correct-password" }

    expect(response.status).to eq(403)
    expect(user.reload.active).to eq(true)
  end

  it "keeps IP addresses unchanged by default" do
    original_ip = user.ip_address

    post "/account-anonymizer/anonymize.json", params: { password: "correct-password" }

    expect(response.status).to eq(200)
    expect(user.reload.ip_address).to eq(original_ip)
  end

  it "anonymizes the user IP when explicitly enabled and blocks a late deferred IP rewrite" do
    SiteSetting.account_anonymizer_anonymize_ip = true
    old_ip = user.ip_address

    post "/account-anonymizer/anonymize.json", params: { password: "correct-password" }

    expect(response.status).to eq(200)
    expect(user.reload.ip_address.to_s).to eq("0.0.0.0")

    # Simulate the deferred update scheduled by DefaultCurrentUserProvider at
    # the start of the request completing after anonymization committed.
    User.update_ip_address!(
      user.id,
      new_ip: "203.0.113.99",
      old_ip: old_ip,
    )

    expect(user.reload.ip_address.to_s).to eq("0.0.0.0")
    expect(UserIpAddressHistory.where(user_id: user.id)).to be_empty
  end

  it "anonymizes retained authentication-log IPs when IP anonymization is enabled" do
    SiteSetting.account_anonymizer_anonymize_ip = true
    UserAuthTokenLog.create!(
      action: "generate",
      user_id: user.id,
      client_ip: "198.51.100.42",
    )

    post "/account-anonymizer/anonymize.json", params: { password: "correct-password" }

    expect(response.status).to eq(200)
    expect(
      UserAuthTokenLog.where(user_id: user.id).where.not(client_ip: "0.0.0.0"),
    ).to be_empty
  end

  it "keeps ordinary user IP updates unchanged when IP anonymization is enabled" do
    SiteSetting.account_anonymizer_anonymize_ip = true
    ordinary_user = Fabricate(:user)
    old_ip = ordinary_user.ip_address

    User.update_ip_address!(
      ordinary_user.id,
      new_ip: "203.0.113.100",
      old_ip: old_ip,
    )

    expect(ordinary_user.reload.ip_address.to_s).to eq("203.0.113.100")
  end

  it "revokes pre-existing email tokens and passwordless login codes synchronously" do
    old_email = user.email
    email_login = user.email_tokens.create!(email: old_email, scope: EmailToken.scopes[:email_login])
    email_login_token = email_login.token
    password_reset = user.email_tokens.create!(email: old_email, scope: EmailToken.scopes[:password_reset])
    password_reset_token = password_reset.token
    EmailLoginCode.generate!(email: old_email)

    post "/account-anonymizer/anonymize.json", params: { password: "correct-password" }

    expect(response.status).to eq(200)
    expect(EmailToken.confirmable(email_login_token, scope: EmailToken.scopes[:email_login])).to be_nil
    expect(EmailToken.confirmable(password_reset_token, scope: EmailToken.scopes[:password_reset])).to be_nil
    expect(EmailLoginCode.for_email(old_email)).to be_empty
    expect(user.reload.active).to eq(false)
    expect(user.email).to end_with(UserAnonymizer::EMAIL_SUFFIX)
  end

  it "does not block normal reactivation of an ordinary non-anonymized user" do
    ordinary_user = Fabricate(:user)
    ordinary_user.update!(active: false)

    expect { ordinary_user.update!(active: true) }.not_to raise_error
    expect(ordinary_user.reload.active).to eq(true)
  end

  it "keeps the irreversible activation guard active after self-service is disabled" do
    post "/account-anonymizer/anonymize.json", params: { password: "correct-password" }
    expect(response.status).to eq(200)

    SiteSetting.account_anonymizer_enabled = false

    expect { user.reload.update!(active: true) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(user.reload.active).to eq(false)
    expect(user.email).to end_with(UserAnonymizer::EMAIL_SUFFIX)
  end

  it "prevents a self-anonymized account from being reactivated through a later email token" do
    old_email = user.email

    post "/account-anonymizer/anonymize.json", params: { password: "correct-password" }
    expect(response.status).to eq(200)

    user.reload
    token = user.email_tokens.create!(
      email: old_email,
      scope: EmailToken.scopes[:password_reset],
    )
    raw_token = token.token

    # The irreversible lifecycle guard is intentionally independent from the
    # self-service enabled setting.
    SiteSetting.account_anonymizer_enabled = false

    expect(EmailToken.confirm(raw_token, scope: EmailToken.scopes[:password_reset])).to be_nil
    expect(user.reload.active).to eq(false)
    expect(user.email).to end_with(UserAnonymizer::EMAIL_SUFFIX)
  end

  describe "security boundaries" do
    it "rejects ordinary API-key authentication" do
      sign_out
      api_key = ApiKey.create!(user_id: user.id, created_by_id: Discourse.system_user.id)

      get "/account-anonymizer/status.json", headers: { HTTP_API_KEY: api_key.key }

      expect(response.status).to eq(403)
      expect(user.reload.active).to eq(true)
    end

    it "rejects User API keys even when they have the generic write scope" do
      sign_out
      user_api_key = Fabricate(:user_api_key, user: user)
      user_api_key.scopes = [UserApiKeyScope.new(name: "write")]
      user_api_key.save!

      get "/account-anonymizer/status.json", headers: { HTTP_USER_API_KEY: user_api_key.key }
      expect(response.status).to eq(403)

      post "/account-anonymizer/anonymize.json",
           params: { password: "correct-password" },
           headers: { HTTP_USER_API_KEY: user_api_key.key }

      expect(response.status).to eq(403)
      expect(user.reload.active).to eq(true)
      expect(user.email).not_to end_with(UserAnonymizer::EMAIL_SUFFIX)
    end

    it "rejects shared-session authentication without the normal browser UserAuthToken context" do
      sign_out
      token = UserAuthToken.generate!(user_id: user.id)
      shared_key = SecureRandom.hex
      Auth::DefaultCurrentUserProvider.store_shared_session_key(shared_key, token.id.to_s)

      get "/account-anonymizer/status.json", headers: { HTTP_X_SHARED_SESSION_KEY: shared_key }

      expect(response.status).to eq(403)
      expect(user.reload.active).to eq(true)
    end

    it "blocks direct core self-deletion even for a content-free account" do
      empty_user = Fabricate(:user, password: "correct-password")
      sign_in(empty_user)
      SiteSetting.delete_user_self_max_post_count = 100

      delete "/u/#{empty_user.username}.json", params: { context: "/security-test" }

      expect(response.status).to eq(403)
      expect(User.exists?(empty_user.id)).to eq(true)
    end

    it "blocks API-authenticated direct core self-deletion" do
      empty_user = Fabricate(:user, password: "correct-password")
      user_api_key = Fabricate(:user_api_key, user: empty_user)
      user_api_key.scopes = [UserApiKeyScope.new(name: "write")]
      user_api_key.save!
      sign_out

      delete "/u/#{empty_user.username}.json",
             params: { context: "/security-test" },
             headers: { HTTP_USER_API_KEY: user_api_key.key }

      expect(response.status).to eq(403)
      expect(User.exists?(empty_user.id)).to eq(true)
    end

    it "does not let a regular user delete another account through the core endpoint" do
      delete "/u/#{other_user.username}.json", params: { context: "/security-test" }

      expect(response.status).to eq(403)
      expect(User.exists?(other_user.id)).to eq(true)
    end

    it "prevents admin activation of an irreversibly self-anonymized account" do
      post "/account-anonymizer/anonymize.json", params: { password: "correct-password" }
      expect(response.status).to eq(200)

      user.reload
      expect(user.active).to eq(false)
      expect(user.email_tokens).to be_empty

      admin = Fabricate(:admin)
      sign_in(admin)

      put "/admin/users/#{user.id}/activate.json"

      expect(response.status).to eq(403)
      expect(user.reload.active).to eq(false)
      expect(user.email_tokens).to be_empty
    end

    it "keeps normal admin deletion of another eligible user intact" do
      admin = Fabricate(:admin)
      target = Fabricate(:user)
      target_id = target.id
      sign_in(admin)

      delete "/u/#{target.username}.json", params: { context: "/admin-test" }

      expect(response.status).to eq(200)
      expect(User.exists?(target_id)).to eq(false)
    end

    it "keeps native core self-deletion blocked when self-service anonymization is disabled" do
      empty_user = Fabricate(:user, password: "correct-password")
      empty_user_id = empty_user.id
      sign_in(empty_user)
      SiteSetting.account_anonymizer_enabled = false
      SiteSetting.delete_user_self_max_post_count = 100

      delete "/u/#{empty_user.username}.json", params: { context: "/disabled-test" }

      expect(response.status).to eq(403)
      expect(User.exists?(empty_user_id)).to eq(true)
    end

    it "rejects overlong password input before password hashing" do
      original_username = user.username

      post "/account-anonymizer/anonymize.json",
           params: { password: "a" * (User.max_password_length + 1) }

      expect(response.status).to eq(422)
      expect(user.reload.username).to eq(original_username)
      expect(user.active).to eq(true)
    end

    it "rejects passwords supplied in the query string" do
      original_username = user.username

      post "/account-anonymizer/anonymize.json?password=correct-password"

      expect(response.status).to eq(400)
      expect(user.reload.username).to eq(original_username)
      expect(user.active).to eq(true)
    end

    it "rejects non-string password parameters" do
      original_username = user.username

      post "/account-anonymizer/anonymize.json", params: { password: { value: "correct-password" } }

      expect(response.status).to eq(400)
      expect(user.reload.username).to eq(original_username)
      expect(user.active).to eq(true)
    end

    it "does not refresh or recreate the request auth token after successful anonymization" do
      UserAuthToken.where(user_id: user.id).update_all(rotated_at: 2.days.ago)

      post "/account-anonymizer/anonymize.json", params: { password: "correct-password" }

      expect(response.status).to eq(200)
      expect(UserAuthToken.where(user_id: user.id)).to be_empty
      expect(user.reload.active).to eq(false)
    end
  end
end
