Rage.routes.draw do
  scope path: "api" do
    resources :users, only: :create
    post "users/login", to: "sessions#create"
    get "user", to: "current_users#show"
    put "user", to: "current_users#update"

    resources :profiles, only: :show, param: :username do
      resource :follow, only: %i[create destroy]
    end

    get "articles/feed", to: "articles#feed"
    resources :articles, only: %i[index show create update destroy], param: :slug do
      resource :favorite, only: %i[create destroy]
      resources :comments, only: %i[index create destroy]
    end

    resources :tags, only: :index
  end

  # Unknown paths and methods get the API's JSON 404 rather than Rage's plain-text one.
  match "/*", to: "application#route_not_found", via: :all
end
