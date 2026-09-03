# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseAccountAnonymizer::Policy do
  fab!(:user) { Fabricate(:user, password: "correct-password") }

  before do
    SiteSetting.account_anonymizer_enabled = true
    SiteSetting.account_anonymizer_username_prefix = "Deleted-"
    SiteSetting.enable_local_logins = true
    SiteSetting.enable_discourse_connect = false
    Fabricate(:post, user: user)
  end

  it "allows an eligible regular user with content and a local password" do
    expect(described_class.new(user: user).allowed?).to eq(true)
  end

  it "blocks staff permanently" do
    user.update!(moderator: true)
    expect(described_class.new(user: user).reason).to eq(:staff)
  end

  it "does not replace native deletion for an account without content" do
    empty_user = Fabricate(:user, password: "correct-password")
    expect(described_class.new(user: empty_user).reason).to eq(:native_delete_available)
  end

  it "blocks users without a local password" do
    user.user_password.destroy!
    user.reload
    expect(described_class.new(user: user).reason).to eq(:no_password)
  end

  it "blocks custom group owners" do
    group = Fabricate(:group)
    GroupUser.create!(group: group, user: user, owner: true)
    expect(described_class.new(user: user).reason).to eq(:group_owner)
  end
end
