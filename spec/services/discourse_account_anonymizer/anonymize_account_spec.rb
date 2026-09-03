# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseAccountAnonymizer::AnonymizeAccount do
  fab!(:user) { Fabricate(:user, password: "correct-password") }

  before do
    SiteSetting.account_anonymizer_enabled = true
    SiteSetting.account_anonymizer_username_prefix = "Deleted-"
    SiteSetting.account_anonymizer_anonymize_ip = false
    SiteSetting.enable_local_logins = true
    SiteSetting.enable_discourse_connect = false
  end

  it "finishes deactivation when an event handler fails after the core anonymizer commit" do
    post_record = Fabricate(:post, user: user)
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

  it "still deactivates after committed anonymization when the configured prefix changes unexpectedly" do
    allow_any_instance_of(described_class).to receive(:verify_anonymized_state!).and_wrap_original do |method, *args|
      SiteSetting.account_anonymizer_username_prefix = "Different-"
      method.call(*args)
    end

    expect { described_class.new(user: user, password: "correct-password").call }.not_to raise_error

    user.reload
    expect(user.email).to end_with(UserAnonymizer::EMAIL_SUFFIX)
    expect(user.active).to eq(false)
  end

  it "can idempotently finish an already-committed anonymization without checking the obsolete password" do
    DiscourseAccountAnonymizer::UserAnonymizer.new(user, user, {}).make_anonymous
    user.reload
    expect(user.active).to eq(true)

    expect { described_class.new(user: user, password: "definitely-wrong-now").call }.not_to raise_error

    expect(user.reload.active).to eq(false)
    expect(
      UserHistory.exists?(
        action: UserHistory.actions[:deactivate_user],
        target_user_id: user.id,
        acting_user_id: user.id,
      ),
    ).to eq(true)
  end

  it "repairs an email restored after a committed self-anonymization before finalizing" do
    DiscourseAccountAnonymizer::UserAnonymizer.new(user, user, {}).make_anonymous
    user.reload

    user.primary_email.update_columns(
      email: "restored-after-anonymization@example.com",
      normalized_email: "restored-after-anonymization@example.com",
    )
    user.reload
    expect(user.email).to eq("restored-after-anonymization@example.com")

    expect { described_class.new(user: user, password: "obsolete-password").call }.not_to raise_error

    user.reload
    expect(user.email).to end_with(UserAnonymizer::EMAIL_SUFFIX)
    expect(user.active).to eq(false)
  end

  it "does not treat an anonymized-looking email suffix as proof that core anonymization committed" do
    spoofed_email = "looks-anonymous@anonymized.invalid"
    user.primary_email.update_columns(email: spoofed_email, normalized_email: spoofed_email)
    user.reload

    expect do
      described_class.new(user: user, password: "wrong-password").call
    end.to raise_error(described_class::InvalidPassword)

    expect(
      UserHistory.exists?(
        action: UserHistory.actions[:anonymize_user],
        target_user_id: user.id,
        acting_user_id: user.id,
      ),
    ).to eq(false)
    expect(user.reload.active).to eq(true)
  end

  it "leaves an anonymized account active rather than purgeable if the protective deactivation history cannot be written" do
    original_create = UserHistory.method(:create!)
    allow(UserHistory).to receive(:create!) do |attributes|
      if attributes[:action] == UserHistory.actions[:deactivate_user]
        raise "intentional history failure"
      end

      original_create.call(attributes)
    end

    expect { described_class.new(user: user, password: "correct-password").call }.not_to raise_error

    user.reload
    expect(user.email).to end_with(UserAnonymizer::EMAIL_SUFFIX)
    expect(user.active).to eq(true)
    expect(User.exists?(user.id)).to eq(true)
  end

  it "rechecks eligibility after credential revocation before the irreversible core call" do
    allow_any_instance_of(described_class).to receive(:revoke_reactivation_credentials!).and_wrap_original do |method, *args|
      method.call(*args)
      user.update_column(:moderator, true)
    end

    expect do
      described_class.new(user: user, password: "correct-password").call
    end.to raise_error(Discourse::InvalidAccess)

    user.reload
    expect(user.username).not_to start_with("Deleted-")
    expect(user.email).not_to end_with(UserAnonymizer::EMAIL_SUFFIX)
    expect(user.active).to eq(true)
    expect(
      UserHistory.exists?(
        action: UserHistory.actions[:anonymize_user],
        target_user_id: user.id,
        acting_user_id: user.id,
      ),
    ).to eq(false)
  end

  it "rechecks the password immediately before the irreversible core call" do
    allow_any_instance_of(described_class).to receive(:revoke_reactivation_credentials!).and_wrap_original do |method, *args|
      method.call(*args)
      user.password = "changed-during-request"
      user.save!
    end

    expect do
      described_class.new(user: user, password: "correct-password").call
    end.to raise_error(described_class::InvalidPassword)

    user.reload
    expect(user.username).not_to start_with("Deleted-")
    expect(user.email).not_to end_with(UserAnonymizer::EMAIL_SUFFIX)
    expect(user.active).to eq(true)
  end

  it "does not revoke passwordless login codes for email metadata on an associated account" do
    unrelated_email = "shared-provider-email@example.com"
    Fabricate(
      :user_associated_account,
      user: user,
      info: { name: user.username, email: unrelated_email },
    )
    EmailLoginCode.generate!(email: unrelated_email)

    expect { described_class.new(user: user, password: "correct-password").call }.not_to raise_error

    expect(EmailLoginCode.for_email(unrelated_email)).to exist
    expect(user.reload.active).to eq(false)
  end

  it "removes pending core email-change records without treating an unconfirmed new address as another account email" do
    pending_new_email = "pending-new-address@example.com"
    request =
      EmailChangeRequest.create!(
        user: user,
        requested_by: user,
        old_email: user.email,
        new_email: pending_new_email,
        change_state: EmailChangeRequest.states[:authorizing_new],
      )

    # A passwordless code for an unconfirmed destination address may belong to
    # a different/future account and must not be swept up by this user's cleanup.
    EmailLoginCode.generate!(email: pending_new_email)

    expect { described_class.new(user: user, password: "correct-password").call }.not_to raise_error

    expect(EmailChangeRequest.where(id: request.id)).not_to exist
    expect(EmailLoginCode.for_email(pending_new_email)).to exist
    expect(user.reload.active).to eq(false)
  end

  it "does not cascade-delete an email token owned by another user from a malformed email-change request" do
    other_user = Fabricate(:user)
    foreign_token =
      other_user.email_tokens.create!(
        email: other_user.email,
        scope: EmailToken.scopes[:email_update],
      )

    malformed_request =
      EmailChangeRequest.create!(
        user: user,
        requested_by: user,
        old_email: user.email,
        new_email: "pending-address@example.com",
        change_state: EmailChangeRequest.states[:authorizing_new],
        new_email_token: foreign_token,
      )

    service = described_class.new(user: user, password: "correct-password")
    service.send(:revoke_email_change_requests!)

    expect(EmailChangeRequest.where(id: malformed_request.id)).not_to exist
    expect(EmailToken.where(id: foreign_token.id)).to exist
  end

  it "continues residual credential revocation when one cleanup step fails" do
    service = described_class.new(user: user, password: "correct-password")

    allow(Discourse).to receive(:warn_exception)
    expect(service).to receive(:revoke_email_change_requests!).once
    allow(service).to receive(:revoke_email_tokens!).and_raise("intentional email-token failure")
    expect(service).to receive(:revoke_user_auth_tokens!).once
    expect(service).to receive(:revoke_email_login_codes!).once

    expect { service.send(:revoke_residual_credentials!) }.not_to raise_error
  end

  it "still enqueues core anonymize cleanup when username propagation retry fails" do
    service = described_class.new(user: user, password: "correct-password")
    original_username = user.username
    original_email = user.email

    allow(Discourse).to receive(:warn_exception)
    allow(UsernameChanger).to receive(:update_username).and_raise(
      "intentional username propagation failure",
    )
    expect(Jobs).to receive(:enqueue).with(
      :anonymize_user,
      user_id: user.id,
      prev_emails: [original_email],
      prev_username: original_username,
      anonymize_ip: nil,
    )

    expect do
      service.send(:reenqueue_core_cleanup, original_username, [original_email], {})
    end.not_to raise_error
  end

  it "does not alter Discourse core staff anonymization username behavior" do
    target = Fabricate(:user)
    admin = Fabricate(:admin)

    ::UserAnonymizer.new(target, admin).make_anonymous

    expect(target.reload.username).to start_with("anon")
    expect(target.username).not_to start_with("Deleted-")
  end
end
