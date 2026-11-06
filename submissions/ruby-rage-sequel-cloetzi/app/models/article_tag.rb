class ArticleTag < Sequel::Model
  many_to_one :article
  many_to_one :tag
end
