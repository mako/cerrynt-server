Rails.application.routes.draw do
  namespace :api do
    namespace :v1 do
      post "login", to: "sessions#create"
      get  "me",    to: "users#show"

      resources :feeds, only: [:index, :create, :destroy]
      resources :items, only: [:index, :update]
    end
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
