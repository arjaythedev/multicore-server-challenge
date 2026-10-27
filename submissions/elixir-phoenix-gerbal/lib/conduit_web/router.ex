defmodule ConduitWeb.Router do
  use ConduitWeb, :router

  alias ConduitWeb.Plugs.Authenticate

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :optional_auth do
    plug Authenticate, :optional
  end

  pipeline :required_auth do
    plug Authenticate, :required
  end

  scope "/api", ConduitWeb do
    pipe_through :api

    post "/users", UserController, :create
    post "/users/login", SessionController, :create
    get "/tags", TagController, :index

    scope "/" do
      pipe_through :required_auth

      get "/user", UserController, :show
      put "/user", UserController, :update

      post "/profiles/:username/follow", FollowController, :create
      delete "/profiles/:username/follow", FollowController, :delete

      # Before GET /articles/:slug, so "feed" isn't taken for a slug.
      get "/articles/feed", ArticleController, :feed
      post "/articles", ArticleController, :create
      put "/articles/:slug", ArticleController, :update
      delete "/articles/:slug", ArticleController, :delete

      post "/articles/:slug/favorite", FavoriteController, :create
      delete "/articles/:slug/favorite", FavoriteController, :delete

      post "/articles/:slug/comments", CommentController, :create
      delete "/articles/:slug/comments/:id", CommentController, :delete
    end

    scope "/" do
      pipe_through :optional_auth

      get "/profiles/:username", ProfileController, :show
      get "/articles", ArticleController, :index
      get "/articles/:slug", ArticleController, :show
      get "/articles/:slug/comments", CommentController, :index
    end
  end
end
