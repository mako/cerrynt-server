require "rails_helper"
require "rake"
require "stringio"

RSpec.describe "demo:account", type: :task do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("demo:account")
  end

  around do |example|
    orig_email = ENV["DEMO_USER_EMAIL"]
    orig_password = ENV["DEMO_USER_PASSWORD"]
    ENV.delete("DEMO_USER_EMAIL")
    ENV.delete("DEMO_USER_PASSWORD")
    example.run
  ensure
    orig_email.nil? ? ENV.delete("DEMO_USER_EMAIL") : ENV["DEMO_USER_EMAIL"] = orig_email
    orig_password.nil? ? ENV.delete("DEMO_USER_PASSWORD") : ENV["DEMO_USER_PASSWORD"] = orig_password
  end

  def invoke_task
    task = Rake::Task["demo:account"]
    task.reenable
    stdout = StringIO.new
    stderr = StringIO.new
    orig_stdout = $stdout
    orig_stderr = $stderr
    $stdout = stdout
    $stderr = stderr
    task.invoke
    [ stdout.string, stderr.string ]
  ensure
    $stdout = orig_stdout
    $stderr = orig_stderr
  end

  def invoke_task_capturing_abort
    stdout = StringIO.new
    stderr = StringIO.new
    orig_stdout = $stdout
    orig_stderr = $stderr
    $stdout = stdout
    $stderr = stderr
    task = Rake::Task["demo:account"]
    task.reenable
    expect { task.invoke }.to raise_error(SystemExit)
    [ stdout.string, stderr.string ]
  ensure
    $stdout = orig_stdout
    $stderr = orig_stderr
  end

  it "creates a new user with plan free and does not print the password" do
    password = "demo-password-1234"
    ENV["DEMO_USER_EMAIL"] = "demo@example.com"
    ENV["DEMO_USER_PASSWORD"] = password

    out = nil
    err = nil
    expect {
      out, err = invoke_task
    }.to change(User, :count).by(1)

    user = User.find_by!(email: "demo@example.com")
    expect(user.plan).to eq(Plan::FREE)
    expect(User.authenticate_by(email: "demo@example.com", password: password)).to eq(user)
    expect(out).to include("demo@example.com")
    expect(out).to include("created")
    expect(out).to include("0")
    expect(out).not_to include(password)
    expect(err).to be_empty
  end

  it "does not create a duplicate when rerun with different case and whitespace in the email" do
    ENV["DEMO_USER_EMAIL"] = "demo@example.com"
    ENV["DEMO_USER_PASSWORD"] = "initial-password-123"
    invoke_task

    new_password = "rotated-password-456"
    ENV["DEMO_USER_EMAIL"] = "  DEMO@Example.COM "
    ENV["DEMO_USER_PASSWORD"] = new_password

    out = nil
    expect {
      out, = invoke_task
    }.not_to change(User, :count)

    expect(out).to include("demo@example.com")
    expect(out).to include("updated")
    expect(out).not_to include(new_password)
  end

  it "rotates the password so the old password fails and the new password works, leaving plan unchanged" do
    old_password = "old-demo-password-123"
    new_password = "new-demo-password-456"
    user = create(:user, email: "demo@example.com", password: old_password, plan: Plan::PRO)

    ENV["DEMO_USER_EMAIL"] = "demo@example.com"
    ENV["DEMO_USER_PASSWORD"] = new_password

    invoke_task

    expect(user.reload.plan).to eq(Plan::PRO)
    expect(User.authenticate_by(email: "demo@example.com", password: old_password)).to be_nil
    expect(User.authenticate_by(email: "demo@example.com", password: new_password)).to eq(user)
  end

  it "revokes active tokens, preserves already-revoked tokens, and leaves other users' tokens untouched" do
    user = create(:user, email: "demo@example.com", password: "old-demo-password-123")
    other_user = create(:user, email: "other@example.com", password: "other-password-123")

    active_token1, = ApiToken.issue!(user: user, name: "device-1")
    active_token2, = ApiToken.issue!(user: user, name: "device-2")
    already_revoked_at = 2.days.ago.change(usec: 0)
    already_revoked_token, = ApiToken.issue!(user: user, name: "old-device")
    already_revoked_token.update_columns(revoked_at: already_revoked_at)

    other_token, = ApiToken.issue!(user: other_user, name: "other-device")

    ENV["DEMO_USER_EMAIL"] = "demo@example.com"
    ENV["DEMO_USER_PASSWORD"] = "new-demo-password-456"

    out, = invoke_task

    expect(out).to include("updated")
    expect(out).to include("2")
    expect(active_token1.reload.revoked_at).to be_present
    expect(active_token2.reload.revoked_at).to be_present
    expect(already_revoked_token.reload.revoked_at).to eq(already_revoked_at)
    expect(other_token.reload.revoked_at).to be_nil
  end

  it "aborts with SystemExit and creates nothing when email or password is missing or blank" do
    [
      {},
      { "DEMO_USER_EMAIL" => "demo@example.com" },
      { "DEMO_USER_PASSWORD" => "valid-password-123" },
      { "DEMO_USER_EMAIL" => "   ", "DEMO_USER_PASSWORD" => "valid-password-123" },
      { "DEMO_USER_EMAIL" => "demo@example.com", "DEMO_USER_PASSWORD" => "   " }
    ].each do |env_vars|
      ENV.delete("DEMO_USER_EMAIL")
      ENV.delete("DEMO_USER_PASSWORD")
      env_vars.each { |k, v| ENV[k] = v }

      out = nil
      err = nil
      expect {
        out, err = invoke_task_capturing_abort
      }.not_to change(User, :count)

      expect(out).to be_empty
      expect(err).to include("Missing required environment variable(s):")
    end
  end

  it "aborts on too-short and 73-byte passwords without changing an existing user's password or tokens" do
    old_password = "old-demo-password-123"
    user = create(:user, email: "demo@example.com", password: old_password)
    original_digest = user.password_digest
    active_token, = ApiToken.issue!(user: user, name: "device-1")

    [ "tiny_pw", "a" * 73 ].each do |bad_password|
      ENV["DEMO_USER_EMAIL"] = "demo@example.com"
      ENV["DEMO_USER_PASSWORD"] = bad_password

      out, err = invoke_task_capturing_abort

      expect(out).to be_empty
      expect(err).to include("Demo account validation failed:")
      expect(err).not_to include(bad_password)
      expect(user.reload.password_digest).to eq(original_digest)
      expect(User.authenticate_by(email: "demo@example.com", password: old_password)).to eq(user)
      expect(active_token.reload.revoked_at).to be_nil
      expect(user.api_tokens.active.count).to eq(1)
    end
  end

  it "rolls back the password update if token revocation raises an error" do
    old_password = "old-demo-password-123"
    new_password = "new-demo-password-456"
    user = create(:user, email: "demo@example.com", password: old_password)
    original_digest = user.password_digest

    failing_relation = instance_double(ActiveRecord::Relation)
    allow(failing_relation).to receive(:update_all).and_raise(ActiveRecord::StatementInvalid, "simulated db failure")
    tokens_relation = user.api_tokens
    allow(tokens_relation).to receive(:active).and_return(failing_relation)
    allow(user).to receive(:api_tokens).and_return(tokens_relation)
    allow(User).to receive(:find_by).and_call_original
    allow(User).to receive(:find_by).with(email: "demo@example.com").and_return(user)

    ENV["DEMO_USER_EMAIL"] = "demo@example.com"
    ENV["DEMO_USER_PASSWORD"] = new_password

    expect { invoke_task }.to raise_error(ActiveRecord::StatementInvalid, "simulated db failure")

    expect(user.reload.password_digest).to eq(original_digest)
    expect(User.authenticate_by(email: "demo@example.com", password: old_password)).to eq(user)
    expect(User.authenticate_by(email: "demo@example.com", password: new_password)).to be_nil
  end
end
