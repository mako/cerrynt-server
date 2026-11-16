require "rails_helper"
require "stringio"

RSpec.describe "db/seeds.rb" do
  let(:seeds_path) { Rails.root.join("db/seeds.rb") }

  around do |example|
    orig_email = ENV["SEED_USER_EMAIL"]
    orig_password = ENV["SEED_USER_PASSWORD"]
    ENV.delete("SEED_USER_EMAIL")
    ENV.delete("SEED_USER_PASSWORD")
    example.run
  ensure
    orig_email.nil? ? ENV.delete("SEED_USER_EMAIL") : ENV["SEED_USER_EMAIL"] = orig_email
    orig_password.nil? ? ENV.delete("SEED_USER_PASSWORD") : ENV["SEED_USER_PASSWORD"] = orig_password
  end

  def run_seeds(env_name: "development")
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new(env_name))
    stdout = StringIO.new
    stderr = StringIO.new
    orig_stdout = $stdout
    orig_stderr = $stderr
    $stdout = stdout
    $stderr = stderr
    load seeds_path
    [ stdout.string, stderr.string ]
  ensure
    $stdout = orig_stdout
    $stderr = orig_stderr
  end

  context "in development" do
    it "skips user creation and prints a hint to stderr when SEED_USER_PASSWORD is unset" do
      out, err = nil
      expect {
        out, err = run_seeds
      }.not_to change(User, :count)

      expect(out).to be_empty
      expect(err).to include("SEED_USER_PASSWORD=<at least 10 characters> bin/rails db:seed")
    end

    it "treats empty or whitespace-only SEED_USER_PASSWORD as unset" do
      [ "", "   \t\n " ].each do |blank_password|
        ENV["SEED_USER_PASSWORD"] = blank_password
        out, err = nil
        expect {
          out, err = run_seeds
        }.not_to change(User, :count)

        expect(out).to be_empty
        expect(err).to include("SEED_USER_PASSWORD=<at least 10 characters> bin/rails db:seed")
      end
    end

    it "creates the seed user when SEED_USER_PASSWORD is set and does not print the password" do
      password = "dev-seed-password-123"
      ENV["SEED_USER_PASSWORD"] = password

      out, err = nil
      expect {
        out, err = run_seeds
      }.to change(User, :count).by(1)

      expect(err).to be_empty
      expect(out).to include("Seed user ready:")
      expect(out).to include("you@example.com")
      expect(out).not_to include(password)
      expect(User.authenticate_by(email: "you@example.com", password: password)).to be_present
    end

    it "raises ActiveRecord::RecordInvalid when SEED_USER_PASSWORD is too short" do
      ENV["SEED_USER_PASSWORD"] = "short"

      expect { run_seeds }.to raise_error(ActiveRecord::RecordInvalid, /Password is too short/)
    end

    it "is idempotent when run twice and keeps existing user unchanged when SEED_USER_PASSWORD is unset" do
      original_password = "original-password-123"
      ENV["SEED_USER_PASSWORD"] = original_password
      run_seeds

      ENV.delete("SEED_USER_PASSWORD")
      out, err = nil
      expect {
        out, err = run_seeds
      }.not_to change(User, :count)

      expect(err).to be_empty
      expect(out).to include("already exists")
      expect(out).to include("password unchanged")
      expect(out).not_to include("SEED_USER_PASSWORD=")
      expect(User.authenticate_by(email: "you@example.com", password: original_password)).to be_present
    end

    it "does not change the password when user exists and a different SEED_USER_PASSWORD is set" do
      original_password = "original-password-123"
      other_password = "different-password-456"
      ENV["SEED_USER_PASSWORD"] = original_password
      run_seeds

      ENV["SEED_USER_PASSWORD"] = other_password
      out, err = nil
      expect {
        out, err = run_seeds
      }.not_to change(User, :count)

      expect(err).to be_empty
      expect(out).to include("already exists")
      expect(out).to include("password unchanged")
      expect(User.authenticate_by(email: "you@example.com", password: original_password)).to be_present
      expect(User.authenticate_by(email: "you@example.com", password: other_password)).to be_nil
    end
  end

  context "in non-development environments" do
    it "does nothing even when SEED_USER_PASSWORD is set" do
      ENV["SEED_USER_PASSWORD"] = "dev-seed-password-123"

      %w[test production].each do |env_name|
        out, err = nil
        expect {
          out, err = run_seeds(env_name: env_name)
        }.not_to change(User, :count)

        expect(out).to be_empty
        expect(err).to be_empty
      end
    end
  end
end
