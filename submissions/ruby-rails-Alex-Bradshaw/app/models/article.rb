class Article < ApplicationRecord
  # Title, description and body must be non-empty strings when given.
  TEXT_FIELDS = %i[title description body].freeze
end
