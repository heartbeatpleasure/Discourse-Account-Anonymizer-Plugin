# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseAccountAnonymizer::GuardianExtension do
  fab!(:user) { Fabricate(:user, password: "correct-password") }
  fab!(:other_user) { Fabricate(:user, password: "other-password") }
  fab!(:admin) { Fabricate(:admin) }

  before do
    SiteSetting.account_anonymizer_enabled = true
    SiteSetting.delete_user_self_max_post_count = 0
  end

  it "blocks direct core self-deletion when the user has content regardless of the core threshold" do
    Fabricate(:post, user: user)
    SiteSetting.delete_user_self_max_post_count = 10

    expect(Guardian.new(user).can_delete_user?(user)).to eq(false)
  end

  it "blocks direct core self-deletion for moderators" do
    user.update!(moderator: true)
    SiteSetting.delete_user_self_max_post_count = 10

    expect(Guardian.new(user).can_delete_user?(user)).to eq(false)
  end

  it "blocks direct core self-deletion while an admin is impersonating the target user" do
    user.is_impersonating = true

    expect(Guardian.new(user).can_delete_user?(user)).to eq(false)
  end

  it "blocks direct core self-deletion for a custom group owner" do
    group = Fabricate(:group)
    GroupUser.create!(group: group, user: user, owner: true)

    expect(Guardian.new(user).can_delete_user?(user)).to eq(false)
  end

  it "preserves native core deletion for a regular content-free user" do
    expect(Guardian.new(user).can_delete_user?(user)).to eq(true)
  end

  it "does not alter staff authorization for deleting another eligible user" do
    expect(Guardian.new(admin).can_delete_user?(other_user)).to eq(true)
  end

  it "delegates entirely to core when the plugin is disabled" do
    Fabricate(:post, user: user)
    SiteSetting.delete_user_self_max_post_count = 1
    SiteSetting.account_anonymizer_enabled = false

    expect(Guardian.new(user).can_delete_user?(user)).to eq(true)
  end
end
