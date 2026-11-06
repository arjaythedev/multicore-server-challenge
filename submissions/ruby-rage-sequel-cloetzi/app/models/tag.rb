class Tag < Sequel::Model
  many_to_many :articles, join_table: :article_tags

  NAMES = order(:name).select(:name).naked.prepare([:map, :name], :tag_names)

  def self.names = NAMES.call

  # Creates any of `names` that don't exist yet and returns the ids of all of them.
  def self.ids_for(names)
    dataset.insert_conflict(target: :name).multi_insert(names.uniq.map { { name: it } })
    where(name: names).select_map(:id)
  end
end
