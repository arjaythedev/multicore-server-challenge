# Rage parses the request body before routing to a controller, and when it can't (bad JSON, or JSON that isn't
# an object) it answers with an empty 400. Nothing else in this app returns 400, so this turns exactly that
# response into the API's 422 error.
class MalformedBody
  HEADERS = { "content-type" => "application/json; charset=utf-8" }.freeze
  BODY = ['{"errors":{"body":["invalid request"]}}'].freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    response = @app.call(env)
    response[0] == 400 ? [422, HEADERS.dup, BODY] : response
  end
end
