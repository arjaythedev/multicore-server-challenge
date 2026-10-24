Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :api do
    get "tags", to: "tags#index"

    post "users", to: "users#create"
    post "users/login", to: "users#login"
    get "user", to: "users#show"
    put "user", to: "users#update"

    # feed has to come before articles/:slug, or "feed" would be taken as a slug.
    get "articles/feed", to: "articles#feed"
    get "articles", to: "articles#index"
    post "articles", to: "articles#create"
    scope format: false do
      get "articles/:slug", to: "articles#show"
      put "articles/:slug", to: "articles#update"
      delete "articles/:slug", to: "articles#destroy"
      post "articles/:slug/favorite", to: "articles#favorite"
      delete "articles/:slug/favorite", to: "articles#unfavorite"

      get "articles/:slug/comments", to: "comments#index"
      post "articles/:slug/comments", to: "comments#create"
      delete "articles/:slug/comments/:id", to: "comments#destroy"
    end

    # Usernames can contain dots, which Rails would otherwise treat as a format extension (".json").
    scope format: false, constraints: { username: %r{[^/]+} } do
      get "profiles/:username", to: "profiles#show"
      post "profiles/:username/follow", to: "profiles#follow"
      delete "profiles/:username/follow", to: "profiles#unfollow"
    end
  end

  # Anything else gets a JSON 404 rather than Rails' HTML error page (the spec wants JSON errors everywhere).
  match "*path", to: "application#route_not_found", via: :all
end
