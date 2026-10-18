Rails.application.routes.draw do
  namespace :api do
    namespace :v1 do
      resources :registrations, only: :create
      resources :sessions, only: :create
      resource :session, only: :destroy
      resource :me, only: :show, controller: "me"
      resources :subscriptions, only: %i[index create destroy]
      resources :entries, only: :index

      # The catch-all route must remain the LAST route in the api/v1 namespace
      match "*unmatched", to: "errors#not_found", via: :all
    end
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
