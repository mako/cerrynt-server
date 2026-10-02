module Api
  module V1
    class ItemsController < BaseController
      include Pagy::Method

      before_action :set_item, only: [:update]

      def index
        scope = current_user.items.order(published_at: :desc)
        scope = scope.where(feed_id: params[:feed_id]) if params[:feed_id].present?

        if params[:unread].present? && ActiveModel::Type::Boolean.new.cast(params[:unread])
          scope = scope.where(read_at: nil)
        end

        pagy, items = pagy(scope)

        render json: {
          items: ItemSerializer.new(items).as_json,
          meta: { page: pagy.page, pages: pagy.pages, count: pagy.count }
        }
      end

      def update
        read = ActiveModel::Type::Boolean.new.cast(params[:read])
        @item.update!(read_at: read ? Time.current : nil)
        render json: ItemSerializer.new(@item)
      end

      private

      def set_item
        @item = current_user.items.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Item not found" }, status: :not_found
      end
    end
  end
end
