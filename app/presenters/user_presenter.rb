class UserPresenter
  def initialize(user)
    @user = user
  end

  def as_json(*)
    {
      id: @user.id.to_s,
      email: @user.email,
      plan: @user.plan,
      limits: Plan.limits_for(@user.plan),
      usage: {
        feeds: @user.subscriptions.count
      }
    }
  end
end
