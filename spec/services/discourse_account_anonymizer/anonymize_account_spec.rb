# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseAccountAnonymizer::AnonymizeAccount do
  fab!(:user) { Fabricate(:user, password: "correct-password") }
  fab!(:post_record) { Fabricate(:post, user: user) }

  before do
    SiteSetting.account_anonymizer_enabled = true
    SiteSetting.account_anonymizer_username_prefix = "Deleted-"
    SiteSetting.account_anonymizer_anonymize_ip = false
    SiteSetting.enable_local_logins = true
    SiteSetting.enable_discourse_connect = false
  end

  it "finishes deactivation when an event handler fails after the core anonymizer commit" do
    failing_handler = proc { |**| raise "intentional post-commit failure" }
    DiscourseEvent.on(:user_anonymized, &failing_handler)

    expect { described_class.new(user: user, password: "correct-password").call }.not_to raise_error

    user.reload
    expect(user.username).to start_with("Deleted-")
    expect(user.email).to end_with(UserAnonymizer::EMAIL_SUFFIX)
    expect(user.active).to eq(false)
    expect(Post.with_deleted.find(post_record.id).user_id).to eq(user.id)
  ensure
    DiscourseEvent.off(:user_anonymized, &failing_handler) if failing_handler
  end
end
