# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseAccountAnonymizer::GuardianExtension do
  fab!(:user) { Fabricate(:user, password: "correct-password") }
  fab!(:other_user) { Fabricate(:user, password: "other-password") }
  fab!(:admin) { Fabricate(:admin) }

  before do
    SiteSetting.account_anonymizer_enabled = true
    SiteSetting.delete_user_self_max_post_count = 10
  end

  it "blocks core self-deletion for a completely content-free user" do
    expect(Guardian.new(user).can_delete_user?(user)).to eq(false)
  end

  it "blocks core self-deletion when the user has content regardless of the core threshold" do
    Fabricate(:post, user: user)
    expect(Guardian.new(user).can_delete_user?(user)).to eq(false)
  end

  it "blocks direct core self-deletion for moderators" do
    user.update!(moderator: true)
    expect(Guardian.new(user).can_delete_user?(user)).to eq(false)
  end

  it "does not alter staff authorization for deleting another eligible user" do
    expect(Guardian.new(admin).can_delete_user?(other_user)).to eq(true)
  end

  it "blocks staff activation of a self-anonymized inactive account" do
    user.update!(active: false)
    UserHistory.create!(
      action: UserHistory.actions[:anonymize_user],
      target_user_id: user.id,
      acting_user_id: user.id,
    )

    expect(Guardian.new(admin).can_activate?(user)).to eq(false)
  end

  it "does not alter staff activation of an ordinary inactive account" do
    other_user.update!(active: false)

    expect(Guardian.new(admin).can_activate?(other_user)).to eq(true)
  end

  it "keeps hard self-deletion blocked when self-service anonymization is disabled" do
    SiteSetting.account_anonymizer_enabled = false
    expect(Guardian.new(user).can_delete_user?(user)).to eq(false)
  end
end
