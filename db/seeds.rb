if Rails.env.development?
  email    = ENV.fetch("SEED_USER_EMAIL", "you@example.com")
  password = ENV.fetch("SEED_USER_PASSWORD", SecureRandom.hex(12))

  user = User.find_or_create_by!(email: email) do |u|
    u.password = password
  end

  puts "Seed user ready:"
  puts "  email:     #{user.email}"
end
