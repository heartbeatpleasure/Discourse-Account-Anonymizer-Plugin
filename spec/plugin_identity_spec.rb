# frozen_string_literal: true

RSpec.describe "Discourse Account Anonymizer plugin identity" do
  it "uses the repository directory name as the Discourse plugin name" do
    expect(DiscourseAccountAnonymizer::PLUGIN_NAME).to eq("Discourse-Account-Anonymizer-Plugin")
    expect(Discourse.plugins_by_name[DiscourseAccountAnonymizer::PLUGIN_NAME]&.name).to eq(
      "Discourse-Account-Anonymizer-Plugin",
    )
  end

  it "associates its site settings with the same plugin name" do
    expect(SiteSetting.plugins[:account_anonymizer_enabled]).to eq(
      DiscourseAccountAnonymizer::PLUGIN_NAME,
    )
    expect(SiteSetting.plugins[:account_anonymizer_username_prefix]).to eq(
      DiscourseAccountAnonymizer::PLUGIN_NAME,
    )
    expect(SiteSetting.plugins[:account_anonymizer_anonymize_ip]).to eq(
      DiscourseAccountAnonymizer::PLUGIN_NAME,
    )
  end
end
