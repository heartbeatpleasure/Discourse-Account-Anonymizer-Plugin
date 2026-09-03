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


    it "returns anonymize for one post even when Discourse would natively allow one post" do
      SiteSetting.delete_user_self_max_post_count = 1

      get "/account-anonymizer/status.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["mode"]).to eq("anonymize")
    end

    it "returns native_delete for a truly content-free account when core allows it" do
      empty_user = Fabricate(:user, password: "correct-password")
      sign_in(empty_user)
      SiteSetting.delete_user_self_max_post_count = 1

      get "/account-anonymizer/status.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["mode"]).to eq("native_delete")
    end

    it "re-evaluates eligibility after posts are added in the same signed-in session" do
      fresh_user = Fabricate(:user, password: "correct-password")
      sign_in(fresh_user)
      SiteSetting.delete_user_self_max_post_count = 1

      get "/account-anonymizer/status.json"
      expect(response.status).to eq(200)
      expect(response.parsed_body["mode"]).to eq("native_delete")

      3.times { Fabricate(:post, user: fresh_user) }

      get "/account-anonymizer/status.json"
      expect(response.status).to eq(200)
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

  it "anonymizes the user IP when explicitly enabled" do
    SiteSetting.account_anonymizer_anonymize_ip = true

    post "/account-anonymizer/anonymize.json", params: { password: "correct-password" }

    expect(response.status).to eq(200)
    expect(user.reload.ip_address.to_s).to eq("0.0.0.0")
  end

  it "does not replace native deletion for a user without content" do
    empty_user = Fabricate(:user, password: "correct-password")
    sign_in(empty_user)

    post "/account-anonymizer/anonymize.json", params: { password: "correct-password" }

    expect(response.status).to eq(403)
    expect(empty_user.reload.active).to eq(true)
    expect(empty_user.email).not_to end_with(UserAnonymizer::EMAIL_SUFFIX)
  end

  describe "security boundaries" do
    it "rejects ordinary API-key authentication" do
      api_key = ApiKey.create!(user_id: user.id, created_by_id: Discourse.system_user.id)

      get "/account-anonymizer/status.json", headers: { HTTP_API_KEY: api_key.key }

      expect(response.status).to eq(403)
      expect(user.reload.active).to eq(true)
    end

    it "rejects User API keys even when they have the generic write scope" do
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

    it "blocks API-authenticated direct core self-deletion even for a content-free account" do
      empty_user = Fabricate(:user, password: "correct-password")
      user_api_key = Fabricate(:user_api_key, user: empty_user)
      user_api_key.scopes = [UserApiKeyScope.new(name: "write")]
      user_api_key.save!

      delete "/u/#{empty_user.username}.json",
             params: { context: "/security-test" },
             headers: { HTTP_USER_API_KEY: user_api_key.key }

      expect(response.status).to eq(403)
      expect(User.exists?(empty_user.id)).to eq(true)
    end

    it "blocks bypassing the plugin through the core self-delete endpoint when content exists" do
      SiteSetting.delete_user_self_max_post_count = 10
      original_post_id = post_record.id

      delete "/u/#{user.username}.json", params: { context: "/security-test" }

      expect(response.status).to eq(403)
      expect(User.exists?(user.id)).to eq(true)
      expect(Post.with_deleted.find(original_post_id).user_id).to eq(user.id)
    end

    it "does not let a regular user delete another account through the core endpoint" do
      delete "/u/#{other_user.username}.json", params: { context: "/security-test" }

      expect(response.status).to eq(403)
      expect(User.exists?(other_user.id)).to eq(true)
    end

    it "rejects overlong password input before password hashing" do
      original_username = user.username

      post "/account-anonymizer/anonymize.json",
           params: { password: "a" * (User.max_password_length + 1) }

      expect(response.status).to eq(422)
      expect(user.reload.username).to eq(original_username)
      expect(user.active).to eq(true)
    end
  end

end
