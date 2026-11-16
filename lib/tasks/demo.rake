namespace :demo do
  desc "Create or rotate the public demo account from DEMO_USER_EMAIL and DEMO_USER_PASSWORD"
  task account: :environment do
    email = ENV["DEMO_USER_EMAIL"]
    password = ENV["DEMO_USER_PASSWORD"]

    missing = []
    missing << "DEMO_USER_EMAIL" if email.blank?
    missing << "DEMO_USER_PASSWORD" if password.blank?

    abort("Missing required environment variable(s): #{missing.join(', ')}") if missing.any?

    existing = User.find_by(email: email)

    if existing
      revoked_count = 0
      ActiveRecord::Base.transaction do
        existing.update!(password: password)
        revoked_count = existing.api_tokens.active.update_all(revoked_at: Time.current)
      end

      puts "Demo account updated: #{existing.email} (revoked tokens: #{revoked_count})"
    else
      user = User.create!(email: email, password: password, plan: Plan::FREE)

      puts "Demo account created: #{user.email} (revoked tokens: 0)"
    end
  rescue ActiveRecord::RecordInvalid => e
    abort("Demo account validation failed: #{e.record.errors.full_messages.join(', ')}")
  end
end
