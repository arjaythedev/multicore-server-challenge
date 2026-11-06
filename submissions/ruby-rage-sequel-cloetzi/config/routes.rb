Rage.routes.draw do
  scope path: "api" do
    resources :users, only: :create
    post "users/login", to: "sessions#create"
    get "user", to: "current_users#show"
    put "user", to: "current_users#update"

    get "profiles/:username", to: "profiles#show"
    # Nested routes are spelled out: without Active Support's inflector, Rage would name the parent parameter
    # :profil_username and :articl_slug.
    scope path: "profiles/:profile_username" do
      post "follow", to: "follows#create"
      delete "follow", to: "follows#destroy"
    end

    get "articles/feed", to: "articles#feed"
    resources :articles, only: %i[index show create update destroy], param: :slug
    scope path: "articles/:article_slug" do
      post "favorite", to: "favorites#create"
      delete "favorite", to: "favorites#destroy"
      get "comments", to: "comments#index"
      post "comments", to: "comments#create"
      delete "comments/:id", to: "comments#destroy"
    end

    resources :tags, only: :index
  end

  # Unknown paths and methods get the API's JSON 404 rather than Rage's plain-text one.
  match "/*", to: "application#route_not_found", via: :all
end
