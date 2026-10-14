# frozen_string_literal: true

module Api
  module V1
    class SubscriptionsController < BaseController
      USER_LIMIT = 20
      USER_WINDOW = 10.minutes

      rate_limit to: USER_LIMIT, within: USER_WINDOW,
                 by: -> { current_user.id },
                 name: "subscriptions-user",
                 with: -> { render_rate_limited(USER_WINDOW) },
                 only: :create

      def index
        subscriptions = current_user.subscriptions.includes(:feed).order(:created_at, :id)
        feed_ids = subscriptions.map(&:feed_id)

        unread_counts = Entry.unread_counts_for(current_user, feed_ids)

        render json: {
          subscriptions: subscriptions.map do |subscription|
            SubscriptionPresenter.new(
              subscription,
              unread_count: unread_counts[subscription.feed_id] || 0
            ).as_json
          end
        }
      end

      def create
        result = Subscriptions::Subscribe.call(user: current_user, url: params[:url])

        if result.created?
          render json: { subscription: SubscriptionPresenter.new(result.subscription).as_json },
                 status: :created
        elsif result.existing?
          render json: { subscription: SubscriptionPresenter.new(result.subscription).as_json },
                 status: :ok
        elsif result.error == :busy
          render_rate_limited(Feeds::FetchGate::RETRY_AFTER)
        else
          status = (result.error == :feed_limit_reached) ? :forbidden : :unprocessable_content

          render_error(
            code: result.error,
            message: result.message,
            status: status,
            details: result.details
          )
        end
      end

      def destroy
        subscription = current_user.subscriptions.find(params[:id])
        subscription.destroy!
        head :no_content
      end
    end
  end
end
