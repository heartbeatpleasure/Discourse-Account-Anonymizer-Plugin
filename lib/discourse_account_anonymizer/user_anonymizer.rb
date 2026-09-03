# frozen_string_literal: true

module DiscourseAccountAnonymizer
  class UsernameGenerationError < StandardError
  end

  # Keep all anonymization behavior in Discourse core. We override only the
  # private username generator so there is one username transition:
  # original_username -> Deleted-########.
  class UserAnonymizer < ::UserAnonymizer
    MAX_USERNAME_ATTEMPTS = 100
    RANDOM_SUFFIX_SIZE = 100_000_000

    private

    def make_anon_username
      prefix = SiteSetting.account_anonymizer_username_prefix.to_s

      MAX_USERNAME_ATTEMPTS.times do
        suffix = format("%08d", SecureRandom.random_number(RANDOM_SUFFIX_SIZE))
        candidate = "#{prefix}#{suffix}"

        next if User.where(username_lower: candidate.downcase).exists?
        next if User.reserved_username?(candidate)

        validator = UsernameValidator.new(candidate, object: @user)
        next unless validator.valid_format?

        return candidate
      end

      raise UsernameGenerationError, "Failed to generate a unique anonymized username"
    end
  end
end
