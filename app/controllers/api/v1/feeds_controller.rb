module Api
  module V1
    class FeedsController < BaseController
      def index
        render json: FeedSerializer.new(current_user.feeds.order(:title))
      end

      def create
        feed = current_user.feeds.build(feed_params)

        if feed.save
          FeedFetchJob.perform_later(feed)
          render json: FeedSerializer.new(feed), status: :created
        else
          render json: { errors: feed.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        feed = current_user.feeds.find(params[:id])
        feed.destroy
        head :no_content
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Feed not found" }, status: :not_found
      end

      private

      def feed_params
        params.require(:feed).permit(:url)
      end
    end
  end
end
