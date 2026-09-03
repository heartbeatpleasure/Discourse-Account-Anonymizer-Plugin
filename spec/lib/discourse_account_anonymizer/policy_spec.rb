# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseAccountAnonymizer::Policy do
  fab!(:user) { Fabricate(:user, password: "correct-password") }

  before do
    SiteSetting.account_anonymizer_enabled = true
    SiteSetting.account_anonymizer_username_prefix = "Deleted-"
    SiteSetting.enable_local_logins = true
    SiteSetting.enable_discourse_connect = false
  end

  it "allows an eligible regular user even when the account has no forum content" do
    expect(described_class.new(user: user).allowed?).to eq(true)
  end

  it "allows an eligible regular user with forum content" do
    Fabricate(:post, user: user)
    expect(described_class.new(user: user).allowed?).to eq(true)
  end

  it "blocks staff permanently" do
    user.update!(moderator: true)
    expect(described_class.new(user: user).reason).to eq(:staff)
  end

  it "blocks users without a local password" do
    user.user_password.destroy!
    user.reload
    expect(described_class.new(user: user).reason).to eq(:no_password)
  end

  it "does not let custom group ownership become a denial-of-service against account anonymization" do
    group = Fabricate(:group)
    GroupUser.create!(group: group, user: user, owner: true)

    expect(described_class.new(user: user).allowed?).to eq(true)
  end

  it "blocks impersonated sessions" do
    user.is_impersonating = true
    expect(described_class.new(user: user).reason).to eq(:impersonating)
  end

  it "blocks silenced users" do
    user.update!(silenced_till: 1.day.from_now)
    expect(described_class.new(user: user).reason).to eq(:silenced)
  end

  it "does not let a pending post reviewable created by another user block anonymization" do
    post = Fabricate(:post, user: user)
    ReviewableFlaggedPost.needs_review!(target: post, created_by: Fabricate(:user))

    expect(described_class.new(user: user).allowed?).to eq(true)
  end

  it "blocks a pending account-level ReviewableUser so moderation cannot be bypassed" do
    ReviewableUser.needs_review!(target: user, created_by: Discourse.system_user)

    expect(described_class.new(user: user).reason).to eq(:pending_account_review)
  end

  it "blocks DiscourseConnect because the self-service flow requires a local password login model" do
    SiteSetting.enable_discourse_connect = true
    expect(described_class.new(user: user).reason).to eq(:unsupported_auth)
  end
end
