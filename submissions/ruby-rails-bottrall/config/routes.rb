Rails.application.routes.draw do
  scope :api, format: false do
    resources :users, only: :create
    post "users/login", to: "sessions#create"
    resource :user, only: %i[show update], controller: :current_users

    resources :profiles, only: :show, param: :username, constraints: { username: %r{[^/]+} } do
      resource :follow, only: %i[create destroy]
    end

    get "articles/feed", to: "articles#feed"
    resources :articles, only: %i[index show create update destroy], param: :slug, constraints: { slug: %r{[^/]+} } do
      resource :favorite, only: %i[create destroy]
      resources :comments, only: %i[index create destroy]
    end

    resources :tags, only: :index
  end

  # Unknown paths and methods get the API's JSON 404 rather than Rails' HTML one.
  match "*path", to: "application#route_not_found", via: :all, format: false
end
