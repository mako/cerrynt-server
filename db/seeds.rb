if Rails.env.development?
  email = ENV.fetch("SEED_USER_EMAIL", "you@example.com")

  if (existing_user = User.find_by(email: email))
    puts "Seed user already exists (#{existing_user.email}); password unchanged."
  elsif (password = ENV["SEED_USER_PASSWORD"]).blank?
    warn "Seed user not created: set SEED_USER_PASSWORD=<at least 10 characters> bin/rails db:seed"
  else
    user = User.create!(email: email, password: password)

    puts "Seed user ready:"
    puts "  email:     #{user.email}"
  end
end
