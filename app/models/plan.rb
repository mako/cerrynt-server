class Plan
  FREE = "free"
  PRO = "pro"

  PLANS = {
    FREE => { max_feeds: 2 },
    PRO => { max_feeds: 100 }
  }.freeze

  def self.limits_for(plan_name)
    PLANS.fetch(plan_name, PLANS[FREE])
  end
end
